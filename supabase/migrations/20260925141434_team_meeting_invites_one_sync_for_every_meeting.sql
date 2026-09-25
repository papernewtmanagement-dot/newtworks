-- Team meeting invites: one sync for every recurring team meeting.
-- Peter 2026-09-25: two new daily meetings, Daily Wrap-up (5:00-5:30 pm) and
-- Coffee and Donuts (12:30-1:00 pm), with no Meet or Teams link and the same
-- automatic add and remove as the Daily Kickoff. Rather than copy the kickoff
-- sync, agency_huddle_config now holds one row per meeting (meeting_key) and
-- huddle_calendar_sync runs every row through one worker,
-- huddle_calendar_sync_meeting.
-- Also fixed on the way:
--   * the calendar-invite roster now adds a new hire from the Friday before
--     their start date (Peter's rule 2026-09-17), not 7 days out;
--   * a newly created series now has its id read off Google's answer, so the
--     next pass patches it instead of building another one;
--   * one change in flight per meeting, so a slow answer cannot lead to a
--     second series;
--   * a person taken off several meetings gets one note, not one per meeting.

-- 1. One row per meeting.
ALTER TABLE public.agency_huddle_config
  ADD COLUMN IF NOT EXISTS meeting_key text NOT NULL DEFAULT 'daily_kickoff';
ALTER TABLE public.agency_huddle_config
  ADD COLUMN IF NOT EXISTS calendar_last_dispatch_action text;

COMMENT ON COLUMN public.agency_huddle_config.meeting_key IS
  'Which recurring team meeting this row is. daily_kickoff also carries the kickoff leader rotation and notes. Every row carries its own Google Calendar series. The default stays daily_kickoff so anything written before there were several meetings still means the kickoff.';
COMMENT ON COLUMN public.agency_huddle_config.calendar_last_dispatch_action IS
  'Composio action of the change in flight (GOOGLECALENDAR_CREATE_EVENT or GOOGLECALENDAR_PATCH_EVENT). A create is how the sync knows to read the new series id off the answer.';

ALTER TABLE public.agency_huddle_config DROP CONSTRAINT IF EXISTS agency_huddle_config_pkey;
ALTER TABLE public.agency_huddle_config
  ADD CONSTRAINT agency_huddle_config_pkey PRIMARY KEY (agency_id, meeting_key);

-- 2. The Daily Wrap-up page summary describes the Daily Kickoff only.
CREATE OR REPLACE FUNCTION public.trg_ahc_after_upd_ins()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  -- The summary on the Daily Wrap-up page describes the Daily Kickoff only.
  IF NEW.meeting_key = 'daily_kickoff' THEN
    PERFORM public.refresh_daily_checklist_huddle_summary(NEW.agency_id);
  END IF;
  RETURN NULL;
END;
$function$;

-- 3. Readers that mean the kickoff say so, and the calendar-invite roster
--    follows the Friday-before-start rule. Patched by exact anchor; each
--    anchor must be found exactly once or the migration stops.
DO $patch$
DECLARE
  p record;
  v_def text;
  v_count int;
BEGIN
  FOR p IN
    SELECT * FROM (VALUES
      (1, 'public.render_huddle_summary_md(uuid)'::regprocedure,
       'FROM public.agency_huddle_config WHERE agency_id = p_agency_id;',
       'FROM public.agency_huddle_config WHERE agency_id = p_agency_id AND meeting_key = ''daily_kickoff'';'),
      (2, 'public.daily_checklist_state(date)'::regprocedure,
       'WHERE c.agency_id = v_agency;',
       'WHERE c.agency_id = v_agency AND c.meeting_key = ''daily_kickoff'';'),
      (3, 'public.get_expected_teammates(uuid,text,date,text)'::regprocedure,
       'AND r.start_date <= v_today_ct + 7)))',
       'AND v_today_ct >= public.onboarding_unlock_date(''friday_before_start'', r.start_date))))'),
      (4, 'public.get_expected_teammates(uuid,text,date,text)'::regprocedure,
       '-- start date a week out or nearer. No upper edge: once they are on the',
       '-- start date, from the Friday before it (Peter''s rule 2026-09-17;' || E'\n'
         || '      -- onboarding_unlock_date works that Friday out). No upper edge: once they are on the')
    ) AS t(ord, fn, old_text, new_text)
    ORDER BY ord
  LOOP
    v_def := pg_get_functiondef(p.fn);
    v_count := (length(v_def) - length(replace(v_def, p.old_text, ''))) / length(p.old_text);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'anchor % for % found % times, expected 1', p.ord, p.fn, v_count;
    END IF;
    EXECUTE replace(v_def, p.old_text, p.new_text);
  END LOOP;
END
$patch$;

-- 4. The worker: one meeting at a time.
CREATE OR REPLACE FUNCTION public.huddle_calendar_sync_meeting(p_agency_id uuid, p_meeting_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
-- Keeps ONE recurring team meeting's Google Calendar series in step with the
-- roster. Every team meeting goes through this function; huddle_calendar_sync
-- runs it for each row of agency_huddle_config and sends the taken-off notes.
--   * The guest list is diffed against calendar_pushed_attendees, the list
--     Google last confirmed, never against Google's own array (the organizer
--     sits in that one).
--   * Removal: push the list minus the leavers with send_updates none, so
--     Google mails nobody. The leavers come back in 'notify' for the caller.
--   * Add: push the full roster with send_updates all, so the new teammate
--     gets a real invite. An add and a removal in one pass: removal first,
--     the add on the next tick.
--   * Detail change (time, title, days): send those and NOT the attendees,
--     because resending the attendees resets everyone's yes or no.
--   * No series yet: create it (no Meet link), then read its id off Google's
--     answer on the next pass.
--   * One change in flight at a time. Nothing new is sent until the last
--     change has answered, so a slow answer can never lead to a second series.
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_prev public.agency_huddle_config%ROWTYPE;
  v_label text;
  v_source text := 'huddle_calendar_sync:' || p_meeting_key;
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
  v_new_event_id text;
  v_checked jsonb := '{}'::jsonb;
  v_desired text[];
  v_pushed text[];
  v_to_push text[];
  v_added text[];
  v_removed text[];
  v_send_updates text;
  v_more_to_do boolean := false;
  v_guest_list_only boolean := false;
  v_guest_changed boolean := false;
  v_email text;
  v_still_here boolean;
  v_notify text[] := ARRAY[]::text[];
BEGIN
  SELECT * INTO v_prev FROM public.agency_huddle_config
  WHERE agency_id = p_agency_id AND meeting_key = p_meeting_key;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','noop','reason','no such meeting','meeting',p_meeting_key);
  END IF;
  v_label := COALESCE(NULLIF(btrim(v_prev.event_title), ''), p_meeting_key);

  -- 1. How did the last change land?
  IF v_prev.calendar_last_dispatch_id IS NOT NULL THEN
    SELECT r.status_code, r.content, r.error_msg
      INTO v_status, v_body, v_err
    FROM net._http_response r
    WHERE r.id = v_prev.calendar_last_dispatch_id;

    IF NOT FOUND THEN
      IF v_prev.calendar_last_dispatch_at > now() - interval '15 minutes' THEN
        RETURN jsonb_build_object('status','noop','reason','last change still on its way',
                                  'meeting',p_meeting_key,'title',v_label);
      END IF;
      v_failed := true;
      v_reason := 'no answer came back from Google Calendar';
    ELSE
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
      ELSIF v_prev.calendar_last_dispatch_action = 'GOOGLECALENDAR_CREATE_EVENT' THEN
        BEGIN
          v_new_event_id := NULLIF(btrim(COALESCE(
              v_body::jsonb #>> '{data,response_data,id}',
              v_body::jsonb #>> '{data,id}',
              v_body::jsonb #>> '{data,event,id}')), '');
        EXCEPTION WHEN others THEN
          v_new_event_id := NULL;
        END;
      END IF;
    END IF;

    -- A create that may have landed must never be sent again blind: that is
    -- how everyone gets a second series and a second invite. Built but id not
    -- readable, or no clear answer at all (lost, timed out): stop and ask.
    -- A clear refusal from Composio or Google is safe to retry.
    IF v_prev.calendar_last_dispatch_action = 'GOOGLECALENDAR_CREATE_EVENT'
       AND ((NOT v_failed AND v_new_event_id IS NULL)
            OR (v_failed AND (v_body IS NULL OR v_err IS NOT NULL))) THEN
      PERFORM public.ensure_watcher_task(
        p_agency_id, v_source, NULL,
        v_label || ' calendar invite needs a look',
        'Newtworks asked Google Calendar to set up the ' || v_label || ' series on '
          || COALESCE(v_prev.calendar_id, 'the calendar')
          || ' but could not confirm it. It has stopped rather than try again, because trying again '
          || 'could send everyone a second invite. What came back: '
          || COALESCE(v_reason, left(COALESCE(v_body, ''), 300)),
        'high', 'admin');
      RETURN jsonb_build_object('status','blocked','reason','new series not confirmed',
                                'meeting',p_meeting_key,'title',v_label);
    END IF;

    v_gone := v_failed AND v_prev.calendar_event_id IS NOT NULL
          AND COALESCE(v_reason, '') ~* 'notFound|not found|404|deleted|Resource has been deleted';

    IF v_failed THEN
      PERFORM public.ensure_watcher_task(
          p_agency_id, v_source, NULL,
          v_label || ' calendar sync did not take',
          CASE WHEN v_gone
            THEN 'The ' || v_label || ' calendar series Newtworks was updating no longer exists, so the update was refused. '
              || 'The stored pointer has been cleared and the next sync will create the series again. '
              || 'This happens when the series is edited in Google with "this and following events". '
              || 'What came back: ' || v_reason
            ELSE 'Google Calendar refused the ' || v_label || ' sync and nothing on the calendar changed. '
              || 'What came back: ' || v_reason
          END,
          CASE WHEN v_gone THEN 'medium' ELSE 'high' END,
          'admin');
    ELSE
      PERFORM public.close_watcher_task(p_agency_id, v_source, NULL);
    END IF;

    v_checked := jsonb_build_object(
      'previous_dispatch_id', v_prev.calendar_last_dispatch_id,
      'previous_action', v_prev.calendar_last_dispatch_action,
      'previous_ok', NOT v_failed,
      'previous_reason', v_reason,
      'event_recreated', v_gone,
      'new_event_id', v_new_event_id
    );

    -- A guest list only counts as pushed once Google says it took it. A failed
    -- change drops the pending list so the next run re-diffs against what
    -- Google last actually confirmed.
    UPDATE public.agency_huddle_config
    SET calendar_last_dispatch_id = NULL,
        calendar_last_dispatch_ok = NOT v_failed,
        calendar_event_id = CASE WHEN v_gone THEN NULL
                                 WHEN v_new_event_id IS NOT NULL THEN v_new_event_id
                                 ELSE calendar_event_id END,
        calendar_needs_sync = CASE WHEN v_failed THEN true ELSE calendar_needs_sync END,
        calendar_pushed_attendees = CASE
            WHEN NOT v_failed AND calendar_pending_attendees IS NOT NULL
              THEN calendar_pending_attendees
            WHEN v_gone THEN NULL
            ELSE calendar_pushed_attendees END,
        calendar_pending_attendees = NULL
    WHERE agency_id = p_agency_id AND meeting_key = p_meeting_key;
  END IF;

  -- 2. Work out what, if anything, has moved.
  SELECT * INTO v FROM public.agency_huddle_config
  WHERE agency_id = p_agency_id AND meeting_key = p_meeting_key AND calendar_id IS NOT NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','noop','reason','no calendar configured',
                              'meeting',p_meeting_key,'title',v_label) || v_checked;
  END IF;

  -- Who should be on the invite: the calendar-invite roster (every active
  -- agency teammate, Owner included, plus a new hire from the Friday before
  -- their start date) under both their State Farm and personal address.
  SELECT COALESCE(array_agg(DISTINCT e.email ORDER BY e.email), ARRAY[]::text[])
  INTO v_desired
  FROM (
    SELECT lower(btrim(et.email_sf)) AS email
    FROM public.get_expected_teammates(p_agency_id, 'agency_calendar_invite', NULL) et
    WHERE NULLIF(btrim(COALESCE(et.email_sf,'')),'') IS NOT NULL
    UNION ALL
    SELECT lower(btrim(et.email_personal))
    FROM public.get_expected_teammates(p_agency_id, 'agency_calendar_invite', NULL) et
    WHERE NULLIF(btrim(COALESCE(et.email_personal,'')),'') IS NOT NULL
  ) e;

  IF v.calendar_pushed_attendees IS NOT NULL THEN
    SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::text[])
    INTO v_pushed
    FROM jsonb_array_elements_text(v.calendar_pushed_attendees) AS t(x);

    SELECT COALESCE(array_agg(e ORDER BY e), ARRAY[]::text[]) INTO v_removed
    FROM unnest(v_pushed) e WHERE e <> ALL(v_desired);

    SELECT COALESCE(array_agg(e ORDER BY e), ARRAY[]::text[]) INTO v_added
    FROM unnest(v_desired) e WHERE e <> ALL(v_pushed);

    v_guest_changed := array_length(v_removed,1) IS NOT NULL
                    OR array_length(v_added,1) IS NOT NULL;
  ELSE
    v_pushed := NULL;
    v_guest_changed := true;   -- no record of what Google holds, so re-seed
  END IF;

  IF v.calendar_event_id IS NOT NULL
     AND NOT v_guest_changed
     AND NOT COALESCE(v.calendar_needs_sync, false) THEN
    RETURN jsonb_build_object('status','noop','reason','roster and meeting both unchanged',
                              'meeting',p_meeting_key,'title',v_label) || v_checked;
  END IF;

  v_start_ts := COALESCE(v.event_first_date, CURRENT_DATE)::text
                || 'T' || TO_CHAR(v.start_time_local, 'HH24:MI:SS');
  v_end_ts := COALESCE(v.event_first_date, CURRENT_DATE)::text
              || 'T' || TO_CHAR(v.start_time_local
                                + make_interval(mins => v.duration_regular_min), 'HH24:MI:SS');

  IF v.calendar_event_id IS NULL THEN
    -- Brand new series. Everyone gets a real invite, which is the point. The
    -- description and location come from the config so a rebuild keeps them.
    -- No Meet link, ever.
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
      'event_duration_hour',    v.duration_regular_min / 60,
      'event_duration_minutes', v.duration_regular_min % 60,
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
      -- No record of what Google is holding, so an add cannot be told from a
      -- removal. Push the roster quietly rather than risk mailing everyone
      -- over a difference that may not exist.
      v_to_push := v_desired;
      v_send_updates := 'none';
      v_guest_list_only := true;

    ELSIF array_length(v_removed, 1) IS NOT NULL THEN
      -- Removal pass. Take the leavers off and mail nobody through Google.
      -- Any adds wait for the next tick so they still get a real invite.
      SELECT COALESCE(array_agg(e ORDER BY e), ARRAY[]::text[]) INTO v_to_push
      FROM unnest(v_pushed) e WHERE e = ANY(v_desired);
      v_send_updates := 'none';
      v_guest_list_only := true;
      v_more_to_do := array_length(v_added, 1) IS NOT NULL;

      FOREACH v_email IN ARRAY v_removed LOOP
        -- Do not note someone who is only changing address and is still on the
        -- invite under their other one.
        SELECT EXISTS (
          SELECT 1 FROM public.team t
          WHERE t.agency_id = p_agency_id
            AND (lower(btrim(t.email_sf)) = v_email OR lower(btrim(t.email_personal)) = v_email)
            AND (lower(btrim(COALESCE(t.email_sf,''))) = ANY(v_desired)
                 OR lower(btrim(COALESCE(t.email_personal,''))) = ANY(v_desired))
        ) INTO v_still_here;

        IF NOT v_still_here THEN
          v_notify := v_notify || v_email;
        END IF;
      END LOOP;

    ELSIF array_length(v_added, 1) IS NOT NULL THEN
      -- Add pass. The new teammate needs a real invite.
      v_to_push := v_desired;
      v_send_updates := 'all';
      v_guest_list_only := true;

    ELSE
      -- Guest list is unchanged, so the edit was to the time, title or days.
      -- Everyone should hear about that.
      v_to_push := NULL;
      v_send_updates := 'all';
      v_guest_list_only := false;
    END IF;

    v_action := 'GOOGLECALENDAR_PATCH_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',  v.calendar_id,
      'event_id',     v.calendar_event_id,
      'send_updates', v_send_updates
    );
    IF v_guest_list_only THEN
      -- Guest list changed. Send only that, so the time, title, description
      -- and location are all left exactly as they are.
      v_arguments := v_arguments || jsonb_build_object('attendees', to_jsonb(v_to_push));
    ELSE
      -- Time, title or days changed. Send those and deliberately NOT the guest
      -- list, because resending it wipes everyone's accepted or declined answer.
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
      calendar_last_dispatch_action = v_action,
      -- A pass that did not touch the guest list leaves the recorded one alone.
      calendar_pending_attendees = CASE WHEN v_to_push IS NULL THEN NULL ELSE to_jsonb(v_to_push) END
  WHERE agency_id = p_agency_id AND meeting_key = p_meeting_key;

  RETURN jsonb_build_object(
    'status','dispatched',
    'meeting', p_meeting_key,
    'title', v_label,
    'action', v_action,
    'pg_net_id', v_pg_net_id,
    'send_updates', v_send_updates,
    'guest_list_only', v_guest_list_only,
    'attendees_pushed', COALESCE(array_length(v_to_push, 1), 0),
    'added', COALESCE(v_added, ARRAY[]::text[]),
    'removed', COALESCE(v_removed, ARRAY[]::text[]),
    'notify', v_notify,
    'adds_deferred_to_next_tick', v_more_to_do
  ) || v_checked;
END;
$function$;

-- 5. The sync: every meeting, then one note per person taken off.
CREATE OR REPLACE FUNCTION public.huddle_calendar_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
-- Runs every recurring team meeting in agency_huddle_config (Daily Kickoff,
-- Coffee and Donuts, Daily Wrap-up) through huddle_calendar_sync_meeting, then
-- sends ONE note to each address taken off, naming every meeting it came off
-- in this pass. Called hourly by the "Daily Kickoff Calendar Sync" recipe and
-- straight away by terminate-team-member.
DECLARE
  r record;
  v_res jsonb;
  v_meetings jsonb := '{}'::jsonb;
  v_dispatched int := 0;
  v_notice jsonb := '{}'::jsonb;
  v_email text;
  v_titles text[];
  v_list text;
  v_subject text;
  v_html text;
  v_sent text[] := ARRAY[]::text[];
BEGIN
  FOR r IN
    SELECT c.meeting_key
    FROM public.agency_huddle_config c
    WHERE c.agency_id = p_agency_id AND c.calendar_id IS NOT NULL
    ORDER BY c.start_time_local, c.meeting_key
  LOOP
    v_res := public.huddle_calendar_sync_meeting(p_agency_id, r.meeting_key);
    v_meetings := v_meetings || jsonb_build_object(r.meeting_key, v_res);
    IF v_res->>'status' = 'dispatched' THEN
      v_dispatched := v_dispatched + 1;
    END IF;
    FOR v_email IN SELECT jsonb_array_elements_text(COALESCE(v_res->'notify', '[]'::jsonb)) LOOP
      v_notice := v_notice || jsonb_build_object(v_email,
                    COALESCE(v_notice->v_email, '[]'::jsonb) || to_jsonb(v_res->>'title'));
    END LOOP;
  END LOOP;

  FOR v_email, v_titles IN
    SELECT n.key, ARRAY(SELECT jsonb_array_elements_text(n.value))
    FROM jsonb_each(v_notice) n
  LOOP
    IF cardinality(v_titles) = 1 THEN
      v_subject := 'You have been taken off the ' || v_titles[1];
      v_html := '<p>You have been removed from the Story Agency '
             || replace(replace(replace(v_titles[1], '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
             || ' meeting.</p><p>If it is still showing on your calendar you can delete it. Nothing else is needed.</p>';
    ELSE
      SELECT string_agg('<li>' || replace(replace(replace(u.t, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</li>', '' ORDER BY u.o)
      INTO v_list
      FROM unnest(v_titles) WITH ORDINALITY AS u(t, o);
      v_subject := 'You have been taken off the team meetings';
      v_html := '<p>You have been removed from these Story Agency meetings:</p><ul>' || v_list
             || '</ul><p>If they are still showing on your calendar you can delete them. Nothing else is needed.</p>';
    END IF;
    PERFORM public.composio_send_email(p_agency_id, v_email, v_subject, v_html);
    v_sent := v_sent || v_email;
  END LOOP;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_dispatched > 0 THEN 'dispatched' ELSE 'noop' END,
    'dispatched_count', v_dispatched,
    'removal_notices_sent', to_jsonb(v_sent),
    'meetings', v_meetings);
END;
$function$;

-- 6. Recipe handler: one summary line per meeting in the run log.
CREATE OR REPLACE FUNCTION public.huddle_calendar_sync(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_result jsonb;
  v_summary text;
BEGIN
  v_result := public.huddle_calendar_sync(p_agency_id);
  SELECT string_agg(
           m.key || ': ' || COALESCE(m.value->>'status', 'unknown')
           || CASE WHEN m.value->>'action' IS NOT NULL THEN ' (' || (m.value->>'action') || ')' ELSE '' END
           || CASE WHEN m.value->>'reason' IS NOT NULL THEN ' — ' || (m.value->>'reason') ELSE '' END,
           '; ' ORDER BY m.key)
  INTO v_summary
  FROM jsonb_each(COALESCE(v_result->'meetings', '{}'::jsonb)) m;
  -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
  RETURN v_result || jsonb_build_object(
    'records_processed', COALESCE((v_result->>'dispatched_count')::int, 0),
    'output_summary', COALESCE(v_summary, 'no meetings configured'));
END;
$function$;

-- 7. Only the runner (postgres) and edge functions (service_role) call these.
REVOKE ALL ON FUNCTION public.huddle_calendar_sync_meeting(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.huddle_calendar_sync_meeting(uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.huddle_calendar_sync(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.huddle_calendar_sync(uuid) TO service_role;

-- 8. The recipe's description still described the long-gone UPDATE_EVENT path.
UPDATE public.automation_recipes
SET recipe_description = 'Hourly. Keeps the Google Calendar series of every recurring team meeting in agency_huddle_config (Daily Kickoff, Coffee and Donuts, Daily Wrap-up) in step with the roster: a new teammate is added from the Friday before their start date, a leaver is taken off quietly with one note, detail edits are pushed without resending the guest list. Creates a missing series (no Meet link) and reads its id off the answer. Pure SQL: huddle_calendar_sync runs huddle_calendar_sync_meeting per meeting and dispatches through composio_post.'
WHERE id = 'ae21dcc8-3412-45f7-b102-fb5903986ced';
