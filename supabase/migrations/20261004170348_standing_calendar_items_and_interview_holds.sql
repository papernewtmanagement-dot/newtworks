CREATE OR REPLACE FUNCTION public.standing_calendar_event_create(p_agency_id uuid, p_summary text, p_description text, p_day date,
  p_start time, p_end time, p_byday text, p_exdates text, p_free boolean, p_invitee text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
-- Creates one of Peter's standing calendar items (a weekly series when p_byday is given, else a single event) and
-- returns its event id, or NULL on failure. p_free marks it free so it never blocks booking. Invites p_invitee.
DECLARE v_args jsonb; v_res jsonb; v_rec jsonb := '[]'::jsonb;
BEGIN
  IF p_byday IS NOT NULL THEN
    v_rec := jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || p_byday);
    IF NULLIF(p_exdates, '') IS NOT NULL THEN v_rec := v_rec || to_jsonb('EXDATE;TZID=America/Chicago:' || p_exdates); END IF;
  END IF;
  v_args := jsonb_build_object('calendar_id', 'primary', 'summary', p_summary, 'description', p_description,
    'start_datetime', to_char(p_day + p_start, 'YYYY-MM-DD"T"HH24:MI:SS'), 'end_datetime', to_char(p_day + p_end, 'YYYY-MM-DD"T"HH24:MI:SS'),
    'timezone', 'America/Chicago', 'attendees', jsonb_build_array(p_invitee), 'exclude_organizer', true,
    'create_meeting_room', false, 'send_updates', 'all', 'transparency', CASE WHEN p_free THEN 'transparent' ELSE 'opaque' END);
  IF jsonb_array_length(v_rec) > 0 THEN v_args := v_args || jsonb_build_object('recurrence', v_rec); END IF;
  v_res := public.composio_post_now(public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_CREATE_EVENT', v_args));
  IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN RAISE WARNING 'standing item not created: %', v_res; RETURN NULL; END IF;
  RETURN COALESCE(v_res #>> '{data,id}', v_res #>> '{data,response_data,id}');
END $function$;

CREATE OR REPLACE FUNCTION public.interview_hold_wanted(p_agency_id uuid, p_from date, p_to date, p_now timestamptz DEFAULT now())
RETURNS TABLE(start_at timestamptz, end_at timestamptz) LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
-- Interview times that should carry a hold on Peter's calendar (Peter 2026-10-04): every slot in interview_slot_grid
-- that isn't blacked out, isn't booked (a booked interview takes the hold's place), and whose day hasn't started
-- (once it has, it's too late to book and the time is freed for a new hire).
  SELECT g.start_at, g.end_at FROM public.interview_slot_grid(p_agency_id, p_from, p_to) g
   WHERE NOT g.blacked_out AND g.slot_date > (p_now AT TIME ZONE 'America/Chicago')::date
     AND NOT EXISTS (SELECT 1 FROM hiring_candidates c WHERE c.agency_id = p_agency_id AND c.interview_calendar_event_id IS NOT NULL
                      AND c.interview_scheduled_start < g.end_at AND COALESCE(c.interview_scheduled_end, c.interview_scheduled_start + interval '30 minutes') > g.start_at);
$function$;

CREATE OR REPLACE FUNCTION public.standing_calendar_items_setup(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
-- Puts Peter's standing items on his Google Calendar once (Peter 2026-10-04), each inviting his State Farm email:
--   "Payroll, Lead Flow, EverQuote Entry, Campaigns" weekdays 9:30-10:00 (busy; coaching may move it later that day,
--     or Tue-Fri cancel it; Monday move only)
--   "Bookkeeping, Hiring process, Marketing analysis, Marketing process, Course Prep, Sales process, Reports, to-dos"
--     weekdays 2:30-3:30 (busy; coaching may remove it)
--   Interview slot holds: one weekly series per interview time of day, read from interview_slot_grid (no copy of the
--     times here), free so the booking page still offers them. Dates with no open slot in the next 26 weeks are left
--     out; interview_holds_sync keeps them matched from then on.
-- Ids go to settings standing_payroll_event_id, standing_admin_event_id, interview_hold_series. Skips what exists.
DECLARE v_sf text; v_today date := (now() AT TIME ZONE 'America/Chicago')::date; v_first date; v_id text; g record;
  v_day date; v_ex text; v_series jsonb; v_out jsonb := '{}'::jsonb;
BEGIN
  SELECT NULLIF(btrim(email_sf), '') INTO v_sf FROM team WHERE agency_id = p_agency_id AND role_level = 'Owner' ORDER BY created_at LIMIT 1;
  IF v_sf IS NULL THEN RAISE EXCEPTION 'the owner has no State Farm email'; END IF;
  v_first := v_today + 1;
  WHILE extract(isodow FROM v_first) > 5 LOOP v_first := v_first + 1; END LOOP;

  IF NULLIF(public.get_setting(p_agency_id, 'standing_payroll_event_id'), '') IS NULL THEN
    v_id := public.standing_calendar_event_create(p_agency_id, 'Payroll, Lead Flow, EverQuote Entry, Campaigns',
      'Standing block. When a new hire''s coaching needs this time it moves later that day; Tuesday to Friday it can be canceled. Monday: move only.',
      v_first, time '09:30', time '10:00', 'MO,TU,WE,TH,FR', NULL, false, v_sf);
    IF v_id IS NULL THEN RAISE EXCEPTION 'Payroll block not created'; END IF;
    PERFORM public.set_setting(p_agency_id, 'standing_payroll_event_id', v_id); v_out := v_out || jsonb_build_object('payroll', v_id);
  END IF;
  IF NULLIF(public.get_setting(p_agency_id, 'standing_admin_event_id'), '') IS NULL THEN
    v_id := public.standing_calendar_event_create(p_agency_id, 'Bookkeeping, Hiring process, Marketing analysis, Marketing process, Course Prep, Sales process, Reports, to-dos',
      'Standing block. Removed on days a new hire''s coaching needs this time.',
      v_first, time '14:30', time '15:30', 'MO,TU,WE,TH,FR', NULL, false, v_sf);
    IF v_id IS NULL THEN RAISE EXCEPTION 'Admin block not created'; END IF;
    PERFORM public.set_setting(p_agency_id, 'standing_admin_event_id', v_id); v_out := v_out || jsonb_build_object('admin', v_id);
  END IF;

  IF NULLIF(public.get_setting(p_agency_id, 'interview_hold_series'), '') IS NULL THEN
    v_series := '[]'::jsonb;
    FOR g IN
      WITH gr AS (SELECT slot_date, (start_at AT TIME ZONE 'America/Chicago')::time AS t, end_at - start_at AS dur
                    FROM public.interview_slot_grid(p_agency_id, v_first, v_first + 55)),
           wk AS (SELECT t, extract(isodow FROM slot_date)::int AS dow, max(dur) AS dur FROM gr
                   GROUP BY t, extract(isodow FROM slot_date) HAVING count(DISTINCT slot_date) >= 3)
      SELECT t, max(dur) AS dur, array_agg(dow ORDER BY dow) AS dows FROM wk GROUP BY t ORDER BY t
    LOOP
      v_day := v_first;
      WHILE NOT (extract(isodow FROM v_day)::int = ANY(g.dows)) LOOP v_day := v_day + 1; END LOOP;
      SELECT string_agg(to_char(d::date + g.t, 'YYYYMMDD"T"HH24MISS'), ',' ORDER BY d) INTO v_ex
        FROM generate_series(v_day, v_day + 182, interval '1 day') d
       WHERE extract(isodow FROM d)::int = ANY(g.dows)
         AND NOT EXISTS (SELECT 1 FROM public.interview_hold_wanted(p_agency_id, v_day, v_day + 182) w
                          WHERE w.start_at = (d::date + g.t) AT TIME ZONE 'America/Chicago');
      v_id := public.standing_calendar_event_create(p_agency_id, 'Interview slot (open)',
        'Held for interviews. Free on purpose so the booking page still offers it. A booked interview takes its place; it comes off once its day starts unbooked.',
        v_day, g.t, g.t + g.dur, (SELECT string_agg((ARRAY['MO','TU','WE','TH','FR','SA','SU'])[x], ',' ORDER BY x) FROM unnest(g.dows) x),
        v_ex, true, v_sf);
      IF v_id IS NULL THEN RAISE EXCEPTION 'hold series % not created', g.t; END IF;
      v_series := v_series || jsonb_build_object('event_id', v_id, 'time', to_char(g.t, 'HH24:MI'), 'days', to_jsonb(g.dows));
    END LOOP;
    PERFORM public.set_setting(p_agency_id, 'interview_hold_series', v_series::text); v_out := v_out || jsonb_build_object('holds', v_series);
  END IF;
  RETURN v_out;
END $function$;

CREATE OR REPLACE FUNCTION public.interview_holds_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid, p_dry_run boolean DEFAULT false, p_now timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
-- Keeps the interview slot holds on Peter's calendar matched to interview_hold_wanted for the next 21 days (Peter
-- 2026-10-04). A hold comes off when its slot is booked (the interview takes its place), blacked out, gone from the
-- grid, or its day has started; a removed hold comes back when its slot opens again (a released booking). An open slot
-- the weekly series don't cover (a one-off manual slot, a released booking on a skipped date) gets a single hold,
-- tracked in settings interview_hold_singles. His State Farm email gets each change. Hourly, 7am-6pm Central.
DECLARE v_series jsonb; s jsonb; v_res jsonb; i jsonb; v_st timestamptz; v_want boolean; v_ok boolean := true;
  v_today date := (p_now AT TIME ZONE 'America/Chicago')::date; v_from timestamptz; v_to timestamptz;
  v_wanted timestamptz[]; v_seen timestamptz[] := '{}'; v_singles jsonb; v_keep jsonb := '{}'::jsonb; k text; v_id text;
  w record; v_sf text; v_removed int := 0; v_restored int := 0; v_created int := 0; v_failed int := 0; v_plan jsonb := '[]'::jsonb;
BEGIN
  v_series := COALESCE(NULLIF(public.get_setting(p_agency_id, 'interview_hold_series'), '')::jsonb, '[]'::jsonb);
  IF jsonb_array_length(v_series) = 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'no hold series yet'); END IF;
  SELECT NULLIF(btrim(email_sf), '') INTO v_sf FROM team WHERE agency_id = p_agency_id AND role_level = 'Owner' ORDER BY created_at LIMIT 1;
  v_from := v_today::timestamp AT TIME ZONE 'America/Chicago';
  v_to := (v_today + 22)::timestamp AT TIME ZONE 'America/Chicago';
  v_wanted := ARRAY(SELECT w2.start_at FROM public.interview_hold_wanted(p_agency_id, v_today, v_today + 21, p_now) w2);

  FOR s IN SELECT x FROM jsonb_array_elements(v_series) x LOOP
    BEGIN
      v_res := public.composio_post_now(public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_EVENTS_INSTANCES', jsonb_build_object(
        'calendarId', 'primary', 'eventId', s->>'event_id', 'showDeleted', true, 'maxResults', 250,
        'timeMin', to_char(v_from AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'timeMax', to_char(v_to AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))));
    EXCEPTION WHEN OTHERS THEN v_res := jsonb_build_object('ok', false, 'error', SQLERRM); END;
    IF NOT COALESCE((v_res->>'ok')::boolean, false) OR jsonb_typeof(COALESCE(v_res #> '{data,items}', v_res #> '{data,response_data,items}')) IS DISTINCT FROM 'array' THEN
      v_ok := false; v_failed := v_failed + 1; CONTINUE;
    END IF;
    FOR i IN SELECT x FROM jsonb_array_elements(COALESCE(v_res #> '{data,items}', v_res #> '{data,response_data,items}')) x LOOP
      v_st := COALESCE(i #>> '{originalStartTime,dateTime}', i #>> '{start,dateTime}')::timestamptz;
      CONTINUE WHEN v_st IS NULL OR v_st < v_from;
      v_seen := v_seen || v_st;
      v_want := v_st = ANY(v_wanted);
      IF COALESCE(i->>'status', 'confirmed') <> 'cancelled' AND NOT v_want THEN
        v_plan := v_plan || jsonb_build_object('remove', v_st);
        IF NOT p_dry_run THEN
          IF COALESCE((public.calendar_delete_event_now(p_agency_id, 'primary', i->>'id')->>'ok')::boolean, false) THEN v_removed := v_removed + 1; ELSE v_failed := v_failed + 1; END IF;
        END IF;
      ELSIF i->>'status' = 'cancelled' AND v_want THEN
        v_plan := v_plan || jsonb_build_object('restore', v_st);
        IF NOT p_dry_run THEN
          v_res := public.composio_post_now(public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_PATCH_EVENT', jsonb_build_object(
                     'calendar_id', 'primary', 'event_id', i->>'id', 'status', 'confirmed', 'send_updates', 'all')));
          IF COALESCE((v_res->>'ok')::boolean, false) THEN v_restored := v_restored + 1; ELSE v_failed := v_failed + 1; END IF;
        END IF;
      END IF;
    END LOOP;
  END LOOP;

  -- singles: only when every series was read, so a read failure never creates duplicates
  v_singles := COALESCE(NULLIF(public.get_setting(p_agency_id, 'interview_hold_singles'), '')::jsonb, '{}'::jsonb);
  IF v_ok THEN
    FOR k, v_id IN SELECT key, value #>> '{}' FROM jsonb_each(v_singles) LOOP
      v_st := k::timestamptz;
      IF v_st < v_from THEN CONTINUE; END IF;
      IF v_st = ANY(v_wanted) AND NOT v_st = ANY(v_seen) THEN v_keep := v_keep || jsonb_build_object(k, v_id); v_seen := v_seen || v_st; CONTINUE; END IF;
      v_plan := v_plan || jsonb_build_object('remove_single', v_st);
      IF NOT p_dry_run THEN
        IF COALESCE((public.calendar_delete_event_now(p_agency_id, 'primary', v_id)->>'ok')::boolean, false) THEN v_removed := v_removed + 1;
        ELSE v_failed := v_failed + 1; v_keep := v_keep || jsonb_build_object(k, v_id); END IF;
      END IF;
    END LOOP;
    FOR w IN SELECT w2.start_at, w2.end_at FROM public.interview_hold_wanted(p_agency_id, v_today, v_today + 21, p_now) w2 WHERE NOT w2.start_at = ANY(v_seen) LOOP
      v_plan := v_plan || jsonb_build_object('add_single', w.start_at);
      IF NOT p_dry_run THEN
        v_id := public.standing_calendar_event_create(p_agency_id, 'Interview slot (open)',
          'Held for interviews. Free on purpose so the booking page still offers it. A booked interview takes its place; it comes off once its day starts unbooked.',
          (w.start_at AT TIME ZONE 'America/Chicago')::date, (w.start_at AT TIME ZONE 'America/Chicago')::time, (w.end_at AT TIME ZONE 'America/Chicago')::time,
          NULL, NULL, true, v_sf);
        IF v_id IS NULL THEN v_failed := v_failed + 1;
        ELSE v_created := v_created + 1; v_keep := v_keep || jsonb_build_object(to_char(w.start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), v_id); END IF;
      END IF;
    END LOOP;
    IF NOT p_dry_run AND v_keep IS DISTINCT FROM v_singles THEN PERFORM public.set_setting(p_agency_id, 'interview_hold_singles', v_keep::text); END IF;
  END IF;

  IF v_failed > 0 AND NOT p_dry_run THEN
    INSERT INTO alerts (agency_id, alert_type, severity, title, message, module_reference)
    VALUES (p_agency_id, 'automation_failure', 'warning', 'Interview holds not fully synced',
            v_failed || ' calendar changes failed; retrying next hour.', 'hiring');
  END IF;
  RETURN jsonb_build_object('ok', v_failed = 0, 'removed', v_removed, 'restored', v_restored, 'created', v_created, 'failed', v_failed)
         || CASE WHEN p_dry_run THEN jsonb_build_object('plan', v_plan) ELSE '{}'::jsonb END;
END $function$;

SELECT cron.schedule('interview-holds-sync', '5 12-23 * * *', 'SELECT public.interview_holds_sync();');
