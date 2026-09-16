-- huddle_calendar_sync fired net.http_post and never looked at the answer. It
-- stamped calendar_needs_sync = false and calendar_last_synced_at = NOW()
-- whether the call worked or not, so a dead calendar_event_id looked like a
-- healthy sync. That is how the pointer sat stale for two months. Any "this and
-- following events" edit in the Google UI mints a new series id and breaks it
-- again the same way.
--
-- Now the function reads the previous dispatch's response at the start of the
-- next run (pg_net keeps responses six hours; this runs every three) and:
--   * raises an alert naming what came back,
--   * clears calendar_event_id when the event is genuinely gone, so the next
--     run recreates the series instead of retrying a dead id forever,
--   * re-flags calendar_needs_sync so the repair actually happens.

ALTER TABLE public.agency_huddle_config
  ADD COLUMN IF NOT EXISTS calendar_last_dispatch_id bigint,
  ADD COLUMN IF NOT EXISTS calendar_last_dispatch_at timestamptz,
  ADD COLUMN IF NOT EXISTS calendar_last_dispatch_ok boolean;

CREATE OR REPLACE FUNCTION public.huddle_calendar_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_prev public.agency_huddle_config%ROWTYPE;
  v_api_key text;
  v_user_id text;
  v_connected_account_id text;
  v_pg_net_id bigint;
  v_attendees jsonb;
  v_start_ts text;
  v_action text;
  v_arguments jsonb;
  v_status int;
  v_body text;
  v_err text;
  v_ok boolean;
  v_failed boolean := false;
  v_gone boolean := false;
  v_reason text;
  v_checked jsonb := '{}'::jsonb;
BEGIN
  -- 1. How did last time's dispatch actually land?
  SELECT * INTO v_prev FROM public.agency_huddle_config WHERE agency_id = p_agency_id;
  IF FOUND AND v_prev.calendar_last_dispatch_id IS NOT NULL THEN
    SELECT r.status_code, r.content, r.error_msg
      INTO v_status, v_body, v_err
    FROM net._http_response r
    WHERE r.id = v_prev.calendar_last_dispatch_id;

    IF FOUND THEN
      -- Composio answers 200 with {"successful": false} on a tool failure, so
      -- the status code alone is not enough.
      BEGIN
        v_ok := (v_body::jsonb->>'successful')::boolean;
      EXCEPTION WHEN others THEN
        v_ok := NULL;
      END;

      v_failed := (v_err IS NOT NULL)
               OR (COALESCE(v_status, 0) >= 400)
               OR (v_ok IS NOT DISTINCT FROM false);

      IF v_failed THEN
        v_reason := COALESCE(v_err, 'HTTP ' || COALESCE(v_status::text, '?')
                    || CASE WHEN v_body IS NOT NULL THEN ' ' || left(v_body, 300) ELSE '' END);
        -- "the event no longer exists" is the failure worth self-healing.
        v_gone := v_prev.calendar_event_id IS NOT NULL
              AND (v_reason ~* 'notFound|not found|404|deleted|Resource has been deleted');

        IF NOT EXISTS (
          SELECT 1 FROM public.alerts
          WHERE agency_id = p_agency_id
            AND module_reference = 'agency_huddle_config'
            AND alert_type = 'huddle_calendar_sync_failed'
            AND is_resolved = false
        ) THEN
          INSERT INTO public.alerts (
            agency_id, alert_type, severity, title, message,
            module_reference, is_read, is_resolved, created_at
          ) VALUES (
            p_agency_id, 'huddle_calendar_sync_failed',
            CASE WHEN v_gone THEN 'warning' ELSE 'error' END,
            'Daily Kickoff calendar sync did not take',
            CASE WHEN v_gone
              THEN 'The calendar event Newtworks was updating no longer exists, so the update was refused. '
                || 'The stored pointer has been cleared and the next sync will create the series again. '
                || 'This happens when the series is edited in Google with "this and following events". '
                || 'What came back: ' || v_reason
              ELSE 'Google Calendar refused the huddle sync and nothing on the calendar changed. '
                || 'What came back: ' || v_reason
            END,
            'agency_huddle_config', false, false, NOW()
          );
        END IF;
      END IF;

      v_checked := jsonb_build_object(
        'previous_dispatch_id', v_prev.calendar_last_dispatch_id,
        'previous_ok', NOT v_failed,
        'previous_reason', v_reason,
        'event_recreated', v_gone
      );

      UPDATE public.agency_huddle_config
      SET calendar_last_dispatch_id = NULL,
          calendar_last_dispatch_ok = NOT v_failed,
          calendar_event_id = CASE WHEN v_gone THEN NULL ELSE calendar_event_id END,
          calendar_needs_sync = CASE WHEN v_failed THEN true ELSE calendar_needs_sync END
      WHERE agency_id = p_agency_id;
    END IF;
  END IF;

  -- 2. Normal sync.
  SELECT * INTO v FROM public.agency_huddle_config
  WHERE agency_id = p_agency_id
    AND calendar_needs_sync = true
    AND calendar_id IS NOT NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','noop','reason','no rows flagged') || v_checked;
  END IF;

  SELECT setting_value INTO v_api_key FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_user_id FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_connected_account_id FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'composio_googlecalendar_account_id';
  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Google Calendar config missing in settings';
  END IF;

  -- Attendees via canonical (agency_active_all, Owner INCLUDED)
  SELECT jsonb_agg(email) INTO v_attendees FROM (
    SELECT et.email_sf AS email
    FROM public.get_expected_teammates(p_agency_id, 'agency_active_all', NULL) et
    WHERE et.email_sf IS NOT NULL AND et.email_sf <> ''
    UNION ALL
    SELECT et.email_personal
    FROM public.get_expected_teammates(p_agency_id, 'agency_active_all', NULL) et
    WHERE et.email_personal IS NOT NULL AND et.email_personal <> ''
  ) e;

  v_start_ts := COALESCE(v.event_first_date, CURRENT_DATE)::text
                || 'T' || TO_CHAR(v.start_time_local, 'HH24:MI:SS');

  IF v.calendar_event_id IS NULL THEN
    v_action := 'GOOGLECALENDAR_CREATE_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',            v.calendar_id,
      'summary',                v.event_title,
      'description',            'Story Agency team huddle. Managed by Newtworks agency_huddle_config. Rhythm + this week''s leader in Newtworks → Playbook → Team Huddle → Daily Rhythm.',
      'start_datetime',         v_start_ts,
      'timezone',               'America/Chicago',
      'event_duration_hour',    0,
      'event_duration_minutes', v.duration_regular_min,
      'recurrence',             jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ',')),
      'attendees',              COALESCE(v_attendees, '[]'::jsonb),
      'create_meeting_room',    true,
      'exclude_organizer',      true,
      'send_updates',           'all',
      'guestsCanInviteOthers',  false,
      'guestsCanSeeOtherGuests', true
    );
  ELSE
    v_action := 'GOOGLECALENDAR_UPDATE_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',            v.calendar_id,
      'event_id',               v.calendar_event_id,
      'summary',                v.event_title,
      'start_datetime',         v_start_ts,
      'timezone',               'America/Chicago',
      'event_duration_hour',    0,
      'event_duration_minutes', v.duration_regular_min,
      'recurrence',             jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ',')),
      'attendees',              COALESCE(v_attendees, '[]'::jsonb),
      'send_updates',           'all'
    );
  END IF;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/' || v_action,
    headers := jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'user_id',              v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments',            v_arguments
    )
  ) INTO v_pg_net_id;

  UPDATE public.agency_huddle_config
  SET calendar_needs_sync = false,
      calendar_last_synced_at = NOW(),
      calendar_last_dispatch_id = v_pg_net_id,
      calendar_last_dispatch_at = NOW(),
      calendar_last_dispatch_ok = NULL
  WHERE agency_id = p_agency_id;

  RETURN jsonb_build_object(
    'status','dispatched',
    'action', v_action,
    'pg_net_id', v_pg_net_id,
    'start_datetime', v_start_ts
  ) || v_checked;
END;
$function$;
