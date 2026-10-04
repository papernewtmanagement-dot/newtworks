
CREATE OR REPLACE FUNCTION public.calendar_busy_now(p_agency_id uuid, p_calendar_id text, p_from timestamptz, p_to timestamptz)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
-- Busy times on a Google Calendar between two moments, read from its events: [{start, end}].
-- Skips all-day items, events marked free, canceled events and anything 12 hours or longer (holiday markers).
-- NULL when the calendar can't be read; callers must never place anything blind.
DECLARE r jsonb; res jsonb;
BEGIN
  BEGIN
    r := public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_EVENTS_LIST', jsonb_build_object(
      'calendarId', p_calendar_id, 'singleEvents', true, 'orderBy', 'startTime', 'maxResults', 250,
      'timeMin', to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'timeMax', to_char(p_to AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'fields', 'items(id,start,end,transparency,status)'));
    res := public.composio_post_now(r);
  EXCEPTION WHEN OTHERS THEN RETURN NULL; END;
  IF NOT COALESCE((res->>'ok')::boolean, false) THEN RETURN NULL; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('start', s, 'end', e) ORDER BY s)
      FROM (SELECT (x #>> '{start,dateTime}')::timestamptz s, (x #>> '{end,dateTime}')::timestamptz e
              FROM jsonb_array_elements(COALESCE(res #> '{data,items}', '[]'::jsonb)) x
             WHERE x #>> '{start,dateTime}' IS NOT NULL
               AND COALESCE(x->>'transparency', 'opaque') <> 'transparent'
               AND COALESCE(x->>'status', 'confirmed') <> 'cancelled') q
     WHERE e - s < interval '12 hours'), '[]'::jsonb);
END $fn$;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_blocks_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_dry_run boolean DEFAULT false, p_now timestamptz DEFAULT now())
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Places Peter's coaching blocks (onboarding_coaching_blocks_plan) on his Google Calendar when each week of a hire's
-- plan opens. Called from onboarding_open_step_notices on the hourly tick. Invites Peter's State Farm email and the
-- hire's State Farm email (team.email_sf, never a personal email) (Peter 2026-10-04).
-- Never double-books (Peter 2026-10-04): each day's time goes only into open time between 9:00 and 17:00 Central on
-- his calendar (calendar_busy_now), split into pieces of 30 minutes or more when needed. Skips company holidays and
-- Peter's approved time off. If the calendar can't be read or a block can't be created, that week's blocks from this
-- run come back off and the whole week retries next hour. Time that doesn't fit raises an alert.
-- A week that opens early first takes down earlier weeks' blocks still ahead.
-- p_dry_run returns what it would place and writes nothing; p_now lets a dry run pretend it is another time.
DECLARE
  p record; w record; d jsonb; e jsonb; b jsonb; k int; i int;
  v_local timestamp := p_now AT TIME ZONE 'America/Chicago';
  v_today date := (p_now AT TIME ZONE 'America/Chicago')::date;
  v_owner uuid; v_owner_sf text; v_att text[]; v_base text; v_events jsonb; v_week jsonb; v_kept jsonb; v_res jsonb; v_key text;
  v_opens date; v_next date; v_start date; v_date date; v_day_start timestamptz; v_day_end timestamptz;
  v_busy jsonb; v_cursor timestamptz; v_gaps jsonb; v_g jsonb; v_parts jsonb; v_pi int; v_left int; v_take int; v_chunk int;
  v_gs timestamptz; v_ge timestamptz; v_lines text[]; v_x int; v_part_left int[];
  v_summary text; v_desc text; v_abort boolean; v_created int := 0; v_removed int := 0; v_failed int := 0; v_preview jsonb := '[]'::jsonb;
BEGIN
  SELECT id, NULLIF(btrim(email_sf), '') INTO v_owner, v_owner_sf FROM team
   WHERE agency_id = p_agency_id AND role_level = 'Owner' ORDER BY created_at LIMIT 1;
  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');
  FOR p IN
    SELECT pl.id, pl.start_date, COALESCE(pl.coaching_events, '{}'::jsonb) AS events, NULLIF(btrim(t.email_sf), '') AS hire_sf,
           COALESCE(NULLIF(btrim(COALESCE(t.nickname, t.first_name)), ''), NULLIF(btrim(c.first_name), ''), 'new hire') AS first_name
      FROM team_onboarding_plans pl
      LEFT JOIN team t ON t.id = pl.team_member_id
      LEFT JOIN hiring_candidates c ON c.id = pl.candidate_id
     WHERE pl.agency_id = p_agency_id AND pl.status = 'active' AND pl.start_date IS NOT NULL
  LOOP
    v_events := p.events;
    v_att := ARRAY(SELECT x FROM unnest(ARRAY[v_owner_sf, p.hire_sf]) x WHERE x IS NOT NULL);
    FOR w IN
      SELECT s.week_no, min(s.phase) AS phase FROM team_onboarding_steps s
       WHERE s.plan_id = p.id AND s.week_no BETWEEN 1 AND 26 GROUP BY s.week_no ORDER BY s.week_no
    LOOP
      CONTINUE WHEN v_events ? w.week_no::text;
      v_opens := public.onboarding_phase_opens_on(p_agency_id, w.phase, p.start_date);
      CONTINUE WHEN v_opens IS NULL OR v_today < v_opens;

      FOR v_key IN SELECT key FROM jsonb_each(v_events) WHERE key ~ '^\d+$' AND key::int < w.week_no LOOP
        v_kept := '[]'::jsonb;
        FOR e IN SELECT x FROM jsonb_array_elements(v_events->v_key) x LOOP
          IF (e->>'start')::timestamptz > p_now THEN
            IF p_dry_run THEN v_removed := v_removed + 1; CONTINUE; END IF;
            IF public.onboarding_coaching_event_remove(p_agency_id, p.id, e) THEN v_removed := v_removed + 1; CONTINUE; END IF;
            v_failed := v_failed + 1;
          END IF;
          v_kept := v_kept || e;
        END LOOP;
        v_events := jsonb_set(v_events, ARRAY[v_key], v_kept);
      END LOOP;

      SELECT public.onboarding_phase_opens_on(p_agency_id, min(s2.phase), p.start_date) INTO v_next
        FROM team_onboarding_steps s2 WHERE s2.plan_id = p.id AND s2.week_no = w.week_no + 1;
      v_start := GREATEST(v_opens, v_today);
      IF v_start = v_today AND v_local::time >= time '09:00' THEN v_start := v_start + 1; END IF;
      WHILE extract(isodow FROM v_start) > 5 LOOP v_start := v_start + 1; END LOOP;

      v_week := '[]'::jsonb; v_abort := false;
      <<days>>
      FOR d IN SELECT x FROM jsonb_array_elements(public.onboarding_coaching_blocks_plan(p.id, w.week_no)) x LOOP
        k := (d->>'day')::int;
        v_date := v_start;
        FOR i IN 2..k LOOP
          v_date := v_date + 1;
          WHILE extract(isodow FROM v_date) > 5 LOOP v_date := v_date + 1; END LOOP;
        END LOOP;
        CONTINUE WHEN v_next IS NOT NULL AND v_date >= v_next;
        CONTINUE WHEN EXISTS (SELECT 1 FROM company_holidays h WHERE h.agency_id = p_agency_id AND h.is_active AND h.holiday_date = v_date);
        CONTINUE WHEN v_owner IS NOT NULL AND EXISTS (SELECT 1 FROM time_off_requests r WHERE r.agency_id = p_agency_id
               AND r.requester_team_id = v_owner AND r.status = 'approved' AND v_date BETWEEN r.start_date AND COALESCE(r.end_date, r.start_date));

        v_day_start := (v_date + time '09:00') AT TIME ZONE 'America/Chicago';
        v_day_end := (v_date + time '17:00') AT TIME ZONE 'America/Chicago';
        v_busy := public.calendar_busy_now(p_agency_id, 'primary', v_day_start, v_day_end);
        IF v_busy IS NULL THEN v_abort := true; EXIT days; END IF;

        v_gaps := '[]'::jsonb; v_cursor := v_day_start;
        FOR b IN SELECT x FROM jsonb_array_elements(v_busy) x ORDER BY (x->>'start')::timestamptz LOOP
          IF (b->>'start')::timestamptz > v_cursor THEN
            v_gaps := v_gaps || jsonb_build_object('s', v_cursor, 'e', LEAST((b->>'start')::timestamptz, v_day_end));
          END IF;
          v_cursor := GREATEST(v_cursor, (b->>'end')::timestamptz);
          EXIT WHEN v_cursor >= v_day_end;
        END LOOP;
        IF v_cursor < v_day_end THEN v_gaps := v_gaps || jsonb_build_object('s', v_cursor, 'e', v_day_end); END IF;

        v_parts := d->'parts';
        v_part_left := ARRAY(SELECT (x->>'minutes')::int FROM jsonb_array_elements(v_parts) x);
        v_pi := 1; v_left := (d->>'minutes')::int;
        FOR v_g IN SELECT x FROM jsonb_array_elements(v_gaps) x LOOP
          EXIT WHEN v_left <= 0;
          v_gs := (v_g->>'s')::timestamptz; v_ge := (v_g->>'e')::timestamptz;
          v_x := (extract(epoch FROM v_ge - v_gs) / 60)::int;
          CONTINUE WHEN v_x < LEAST(30, v_left);
          v_chunk := LEAST(v_x, v_left);
          v_lines := ARRAY[]::text[]; v_take := v_chunk;
          WHILE v_take > 0 AND v_pi <= array_length(v_part_left, 1) LOOP
            v_x := LEAST(v_take, v_part_left[v_pi]);
            v_lines := v_lines || ((v_parts->(v_pi - 1)->>'label') || ' (' || v_x || ' min)');
            v_part_left[v_pi] := v_part_left[v_pi] - v_x; v_take := v_take - v_x;
            IF v_part_left[v_pi] = 0 THEN v_pi := v_pi + 1; END IF;
          END LOOP;
          v_summary := 'Coaching: ' || p.first_name || ', Week ' || w.week_no;
          v_desc := array_to_string(v_lines, E'\n') || E'\n\nPlan: ' || v_base || '/onboarding?plan=' || p.id;
          IF p_dry_run THEN
            v_preview := v_preview || jsonb_build_object('week', w.week_no, 'date', v_date, 'start', v_gs, 'end', v_gs + make_interval(mins => v_chunk), 'covers', to_jsonb(v_lines));
          ELSE
            BEGIN v_res := public.calendar_create_event_now(p_agency_id, 'primary', v_summary, v_desc, v_gs, v_gs + make_interval(mins => v_chunk),
                    CASE WHEN cardinality(v_att) = 0 THEN NULL ELSE v_att END, NULL, false, cardinality(v_att) > 0);
            EXCEPTION WHEN OTHERS THEN v_res := jsonb_build_object('ok', false, 'error', SQLERRM); END;
            IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN v_abort := true; EXIT days; END IF;
            v_week := v_week || jsonb_build_object('day', k, 'date', v_date, 'start', v_gs, 'end', v_gs + make_interval(mins => v_chunk),
                                                   'summary', v_summary, 'description', v_desc, 'event_id', v_res->>'event_id');
            v_created := v_created + 1;
          END IF;
          v_left := v_left - v_chunk;
        END LOOP;
        IF v_left > 0 AND NOT p_dry_run THEN
          INSERT INTO alerts (agency_id, alert_type, severity, title, message, module_reference, related_id)
          VALUES (p_agency_id, 'automation_failure', 'warning', 'Coaching time did not fit',
                  v_left || ' minutes of ' || p.first_name || $$'s Week $$ || w.week_no || ' coaching on ' || to_char(v_date, 'Dy Mon FMDD') ||
                  ' found no open time between 9 and 5.', 'onboarding', p.id);
        ELSIF v_left > 0 THEN
          v_preview := v_preview || jsonb_build_object('week', w.week_no, 'date', v_date, 'did_not_fit_minutes', v_left);
        END IF;
      END LOOP days;

      IF v_abort THEN
        FOR e IN SELECT x FROM jsonb_array_elements(v_week) x LOOP PERFORM public.onboarding_coaching_event_remove(p_agency_id, p.id, e); END LOOP;
        v_created := v_created - jsonb_array_length(v_week); v_failed := v_failed + 1;
        INSERT INTO alerts (agency_id, alert_type, severity, title, message, module_reference, related_id)
        VALUES (p_agency_id, 'automation_failure', 'warning', 'Coaching blocks not placed',
                p.first_name || $$'s Week $$ || w.week_no || ' blocks: the calendar could not be read or written. Retrying next hour. ' || COALESCE(v_res->>'error', ''),
                'onboarding', p.id);
        CONTINUE;
      END IF;
      IF NOT p_dry_run THEN v_events := v_events || jsonb_build_object(w.week_no::text, v_week); END IF;
    END LOOP;

    IF NOT p_dry_run THEN
      UPDATE team_onboarding_plans SET coaching_events = v_events WHERE id = p.id AND coaching_events IS DISTINCT FROM v_events;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('events_created', v_created, 'events_removed', v_removed, 'failed', v_failed)
         || CASE WHEN p_dry_run THEN jsonb_build_object('would_place', v_preview) ELSE '{}'::jsonb END;
END $fn$;
