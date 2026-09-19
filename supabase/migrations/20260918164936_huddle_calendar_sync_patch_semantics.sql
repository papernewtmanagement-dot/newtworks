CREATE OR REPLACE FUNCTION public.huddle_calendar_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
-- Daily Kickoff calendar sync.
--
-- WHY THE GUEST-LIST DIFF EXISTS (Peter, 2026-09-18): this recipe was switched
-- off in August because removing John from the series re-sent the invite to the
-- whole team. Peter's rule is that a removal notifies ONLY the person being
-- removed. Google gives exactly one knob for that, send_updates, and it is
-- all-or-nothing per request. So the function remembers the guest list Google
-- last accepted, works out what actually changed, and picks the knob to match:
--   removal  -> send_updates 'none' (Google mails nobody) plus our own note to
--               the person who came off.
--   add only -> send_updates 'all' so the new teammate gets a real invite.
--   no guest-list change -> the edit was to the time, title or days, so
--               send_updates 'all' and everyone hears about it.
-- An add and a removal in the same pass split across two ticks: the removal
-- goes out quietly first and calendar_needs_sync stays on for the add.
--
-- WHY PATCH AND NOT UPDATE (2026-09-18): the old code called
-- GOOGLECALENDAR_UPDATE_EVENT, which is a full replacement -- every field left
-- out gets cleared. It never sent description or location, so a successful run
-- would have wiped the Microsoft Teams join block and the location off the
-- series. It also never succeeded: Composio rejected its send_updates value
-- outright, so every update dispatch since has come back "Invalid request data
-- provided". PATCH only touches the fields it is given, so the Teams block is
-- safe, and an attendee-only pass now sends nothing but the guest list.
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_prev public.agency_huddle_config%ROWTYPE;
  v_pg_net_id bigint;
  v_start_ts text;
  v_end_ts text;
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
  v_desired text[];
  v_pushed text[];
  v_to_push text[];
  v_added text[];
  v_removed text[];
  v_send_updates text;
  v_more_to_do boolean := false;
  v_guest_list_only boolean := false;
  v_email text;
  v_still_here boolean;
  v_emailed text[] := ARRAY[]::text[];
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

      IF NOT v_failed THEN
        PERFORM public.close_watcher_task(p_agency_id, 'huddle_calendar_sync', NULL);
      END IF;
      IF v_failed THEN
        v_reason := COALESCE(v_err, 'HTTP ' || COALESCE(v_status::text, '?')
                    || CASE WHEN v_body IS NOT NULL THEN ' ' || left(v_body, 300) ELSE '' END);
        v_gone := v_prev.calendar_event_id IS NOT NULL
              AND (v_reason ~* 'notFound|not found|404|deleted|Resource has been deleted');

        PERFORM public.ensure_watcher_task(
            p_agency_id, 'huddle_calendar_sync', NULL,
            'Daily Kickoff calendar sync did not take',
            CASE WHEN v_gone
              THEN 'The calendar event Newtworks was updating no longer exists, so the update was refused. '
                || 'The stored pointer has been cleared and the next sync will create the series again. '
                || 'This happens when the series is edited in Google with "this and following events". '
                || 'What came back: ' || v_reason
              ELSE 'Google Calendar refused the huddle sync and nothing on the calendar changed. '
                || 'What came back: ' || v_reason
            END,
            CASE WHEN v_gone THEN 'medium' ELSE 'high' END,
            'admin');
      END IF;

      v_checked := jsonb_build_object(
        'previous_dispatch_id', v_prev.calendar_last_dispatch_id,
        'previous_ok', NOT v_failed,
        'previous_reason', v_reason,
        'event_recreated', v_gone
      );

      -- A guest list only counts as pushed once Google says it took it. A
      -- failed dispatch drops the pending list so the next run re-diffs against
      -- what Google last actually confirmed.
      UPDATE public.agency_huddle_config
      SET calendar_last_dispatch_id = NULL,
          calendar_last_dispatch_ok = NOT v_failed,
          calendar_event_id = CASE WHEN v_gone THEN NULL ELSE calendar_event_id END,
          calendar_needs_sync = CASE WHEN v_failed THEN true ELSE calendar_needs_sync END,
          calendar_pushed_attendees = CASE
              WHEN NOT v_failed AND calendar_pending_attendees IS NOT NULL
                THEN calendar_pending_attendees
              WHEN v_gone THEN NULL
              ELSE calendar_pushed_attendees END,
          calendar_pending_attendees = NULL
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

  -- Who should be on the invite: every active agency teammate, Owner included,
  -- under both their State Farm and personal address.
  SELECT COALESCE(array_agg(DISTINCT e.email ORDER BY e.email), ARRAY[]::text[])
  INTO v_desired
  FROM (
    SELECT lower(btrim(et.email_sf)) AS email
    FROM public.get_expected_teammates(p_agency_id, 'agency_active_all', NULL) et
    WHERE NULLIF(btrim(COALESCE(et.email_sf,'')),'') IS NOT NULL
    UNION ALL
    SELECT lower(btrim(et.email_personal))
    FROM public.get_expected_teammates(p_agency_id, 'agency_active_all', NULL) et
    WHERE NULLIF(btrim(COALESCE(et.email_personal,'')),'') IS NOT NULL
  ) e;

  IF v.calendar_pushed_attendees IS NOT NULL THEN
    SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::text[])
    INTO v_pushed
    FROM jsonb_array_elements_text(v.calendar_pushed_attendees) AS t(x);
  ELSE
    v_pushed := NULL;
  END IF;

  v_start_ts := COALESCE(v.event_first_date, CURRENT_DATE)::text
                || 'T' || TO_CHAR(v.start_time_local, 'HH24:MI:SS');
  v_end_ts := COALESCE(v.event_first_date, CURRENT_DATE)::text
              || 'T' || TO_CHAR(v.start_time_local
                                + make_interval(mins => v.duration_regular_min), 'HH24:MI:SS');

  IF v.calendar_event_id IS NULL THEN
    -- Brand new series. Everyone gets a real invite, which is the point. The
    -- Teams join block and location come from the config so a rebuild does not
    -- lose them.
    v_to_push := v_desired;
    v_send_updates := 'all';
    v_action := 'GOOGLECALENDAR_CREATE_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',            v.calendar_id,
      'summary',                v.event_title,
      'description',            COALESCE(v.event_description, ''),
      'location',               COALESCE(v.event_location, ''),
      'start_datetime',         v_start_ts,
      'timezone',               'America/Chicago',
      'event_duration_hour',    0,
      'event_duration_minutes', v.duration_regular_min,
      'recurrence',             jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ',')),
      'attendees',              to_jsonb(v_to_push),
      'create_meeting_room',    false,
      'exclude_organizer',      true,
      'send_updates',           v_send_updates,
      'guestsCanInviteOthers',  false,
      'guestsCanSeeOtherGuests', true
    );
  ELSE
    IF v_pushed IS NULL THEN
      -- First run after this change. Newtworks has no record of what Google is
      -- holding, so it cannot tell an add from a removal. Push the roster
      -- quietly rather than risk mailing everyone over a difference that may
      -- not exist.
      v_to_push := v_desired;
      v_send_updates := 'none';
      v_guest_list_only := true;
    ELSE
      SELECT COALESCE(array_agg(e ORDER BY e), ARRAY[]::text[]) INTO v_removed
      FROM unnest(v_pushed) e WHERE e <> ALL(v_desired);

      SELECT COALESCE(array_agg(e ORDER BY e), ARRAY[]::text[]) INTO v_added
      FROM unnest(v_desired) e WHERE e <> ALL(v_pushed);

      IF array_length(v_removed, 1) IS NOT NULL THEN
        -- Removal pass. Take the leavers off and mail nobody through Google.
        -- Any adds wait for the next tick so they still get a real invite.
        SELECT COALESCE(array_agg(e ORDER BY e), ARRAY[]::text[]) INTO v_to_push
        FROM unnest(v_pushed) e WHERE e = ANY(v_desired);
        v_send_updates := 'none';
        v_guest_list_only := true;
        v_more_to_do := array_length(v_added, 1) IS NOT NULL;

        FOREACH v_email IN ARRAY v_removed LOOP
          -- Do not mail someone who is only changing address and is still on
          -- the invite under their other one.
          SELECT EXISTS (
            SELECT 1 FROM public.team t
            WHERE t.agency_id = p_agency_id
              AND (lower(btrim(t.email_sf)) = v_email OR lower(btrim(t.email_personal)) = v_email)
              AND (lower(btrim(COALESCE(t.email_sf,''))) = ANY(v_desired)
                   OR lower(btrim(COALESCE(t.email_personal,''))) = ANY(v_desired))
          ) INTO v_still_here;

          IF NOT v_still_here THEN
            PERFORM public.composio_send_email(
              p_agency_id,
              v_email,
              'You have been taken off the Daily Kickoff',
              '<p>You have been removed from the Story Agency Daily Kickoff meeting.</p>'
              || '<p>If it is still showing on your calendar you can delete it. Nothing else is needed.</p>');
            v_emailed := v_emailed || v_email;
          END IF;
        END LOOP;

      ELSIF array_length(v_added, 1) IS NOT NULL THEN
        -- Add pass. The new teammate needs a real invite.
        v_to_push := v_desired;
        v_send_updates := 'all';
        v_guest_list_only := true;
      ELSE
        -- Guest list is unchanged, so the edit was to the time, title or days.
        -- Everyone should hear about that, and this is the only pass that
        -- touches anything other than the guest list.
        v_to_push := v_desired;
        v_send_updates := 'all';
        v_guest_list_only := false;
      END IF;
    END IF;

    v_action := 'GOOGLECALENDAR_PATCH_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',  v.calendar_id,
      'event_id',     v.calendar_event_id,
      'attendees',    to_jsonb(v_to_push),
      'send_updates', v_send_updates
    );
    IF NOT v_guest_list_only THEN
      v_arguments := v_arguments || jsonb_build_object(
        'summary',    v.event_title,
        'start_time', v_start_ts,
        'end_time',   v_end_ts,
        'timezone',   'America/Chicago',
        'recurrence', jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ','))
      );
    END IF;
  END IF;

  v_pg_net_id := public.composio_post(
    public.composio_tool_request(p_agency_id, v_action, v_arguments));

  UPDATE public.agency_huddle_config
  SET calendar_needs_sync = v_more_to_do,
      calendar_last_synced_at = NOW(),
      calendar_last_dispatch_id = v_pg_net_id,
      calendar_last_dispatch_at = NOW(),
      calendar_last_dispatch_ok = NULL,
      calendar_pending_attendees = to_jsonb(v_to_push)
  WHERE agency_id = p_agency_id;

  RETURN jsonb_build_object(
    'status','dispatched',
    'action', v_action,
    'pg_net_id', v_pg_net_id,
    'send_updates', v_send_updates,
    'guest_list_only', v_guest_list_only,
    'attendees_pushed', COALESCE(array_length(v_to_push, 1), 0),
    'added', COALESCE(v_added, ARRAY[]::text[]),
    'removed', COALESCE(v_removed, ARRAY[]::text[]),
    'removal_notices_sent', v_emailed,
    'adds_deferred_to_next_tick', v_more_to_do
  ) || v_checked;
END;
$function$;
