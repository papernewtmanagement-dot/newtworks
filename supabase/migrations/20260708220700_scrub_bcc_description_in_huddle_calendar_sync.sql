CREATE OR REPLACE FUNCTION public.huddle_calendar_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_api_key text;
  v_user_id text;
  v_connected_account_id text;
  v_pg_net_id bigint;
  v_attendees jsonb;
  v_start_ts text;
  v_action text;
  v_arguments jsonb;
BEGIN
  SELECT * INTO v FROM public.agency_huddle_config
  WHERE agency_id = p_agency_id
    AND calendar_needs_sync = true
    AND calendar_id IS NOT NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','noop','reason','no rows flagged');
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
      calendar_last_synced_at = NOW()
  WHERE agency_id = p_agency_id;

  RETURN jsonb_build_object(
    'status','dispatched',
    'action', v_action,
    'pg_net_id', v_pg_net_id,
    'start_datetime', v_start_ts
  );
END;
$function$
