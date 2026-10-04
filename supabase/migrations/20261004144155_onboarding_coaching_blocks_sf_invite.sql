CREATE OR REPLACE FUNCTION public.onboarding_coaching_blocks_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid, p_dry_run boolean DEFAULT false, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Places Peter's coaching blocks (onboarding_coaching_blocks_plan) on his Google Calendar when each week of a hire's
-- plan opens. Called from onboarding_open_step_notices on the hourly tick. Peter's calendar, with his State Farm email
-- (Owner team.email_sf) invited so it reaches his work calendar (Peter 2026-10-04). The hire is not invited. One event per day at 9:00 Central. Skips company holidays and Peter's approved time off. A week that opens
-- early first takes down earlier weeks' blocks still ahead. A block that failed to place is retried while still ahead.
-- p_dry_run returns what it would place and writes nothing; p_now lets a dry run pretend it is another time.
DECLARE
  p record; w record; d jsonb; e jsonb; k int; i int;
  v_local timestamp := p_now AT TIME ZONE 'America/Chicago';
  v_today date := (p_now AT TIME ZONE 'America/Chicago')::date;
  v_owner uuid; v_sf text; v_base text; v_events jsonb; v_week jsonb; v_kept jsonb; v_res jsonb; v_key text;
  v_opens date; v_next date; v_start date; v_date date; v_st timestamptz; v_en timestamptz;
  v_summary text; v_desc text; v_created int := 0; v_removed int := 0; v_failed int := 0; v_preview jsonb := '[]'::jsonb;
BEGIN
  SELECT id, NULLIF(btrim(email_sf), '') INTO v_owner, v_sf FROM team WHERE agency_id = p_agency_id AND role_level = 'Owner' ORDER BY created_at LIMIT 1;
  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');
  FOR p IN
    SELECT pl.id, pl.start_date, COALESCE(pl.coaching_events, '{}'::jsonb) AS events,
           COALESCE(NULLIF(btrim(COALESCE(t.nickname, t.first_name)), ''), NULLIF(btrim(c.first_name), ''), 'new hire') AS first_name
      FROM team_onboarding_plans pl
      LEFT JOIN team t ON t.id = pl.team_member_id
      LEFT JOIN hiring_candidates c ON c.id = pl.candidate_id
     WHERE pl.agency_id = p_agency_id AND pl.status = 'active' AND pl.start_date IS NOT NULL
  LOOP
    v_events := p.events;
    -- Retry blocks that failed to place and are still ahead.
    IF NOT p_dry_run THEN
      FOR v_key IN SELECT key FROM jsonb_each(v_events) LOOP
        v_kept := '[]'::jsonb;
        FOR e IN SELECT x FROM jsonb_array_elements(v_events->v_key) x LOOP
          IF e->>'event_id' IS NULL AND (e->>'start')::timestamptz > p_now THEN
            BEGIN v_res := public.calendar_create_event_now(p_agency_id, 'primary', e->>'summary', e->>'description',
                    (e->>'start')::timestamptz, (e->>'end')::timestamptz, CASE WHEN v_sf IS NULL THEN NULL ELSE ARRAY[v_sf] END, NULL, false, v_sf IS NOT NULL);
            EXCEPTION WHEN OTHERS THEN v_res := jsonb_build_object('ok', false, 'error', SQLERRM); END;
            IF COALESCE((v_res->>'ok')::boolean, false) THEN
              e := e || jsonb_build_object('event_id', v_res->>'event_id'); v_created := v_created + 1;
            ELSE v_failed := v_failed + 1; END IF;
          END IF;
          v_kept := v_kept || e;
        END LOOP;
        v_events := jsonb_set(v_events, ARRAY[v_key], v_kept);
      END LOOP;
    END IF;

    FOR w IN
      SELECT s.week_no, min(s.phase) AS phase FROM team_onboarding_steps s
       WHERE s.plan_id = p.id AND s.week_no BETWEEN 1 AND 26 GROUP BY s.week_no ORDER BY s.week_no
    LOOP
      CONTINUE WHEN v_events ? w.week_no::text;
      v_opens := public.onboarding_phase_opens_on(p_agency_id, w.phase, p.start_date);
      CONTINUE WHEN v_opens IS NULL OR v_today < v_opens;

      -- Opened early: take down earlier weeks' blocks still ahead.
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

      v_week := '[]'::jsonb;
      FOR d IN SELECT x FROM jsonb_array_elements(public.onboarding_coaching_blocks_plan(p.id, w.week_no)) x LOOP
        k := (d->>'day')::int;
        v_date := v_start;
        FOR i IN 2..k LOOP
          v_date := v_date + 1;
          WHILE extract(isodow FROM v_date) > 5 LOOP v_date := v_date + 1; END LOOP;
        END LOOP;
        CONTINUE WHEN v_next IS NOT NULL AND v_date >= v_next;
        CONTINUE WHEN EXISTS (SELECT 1 FROM company_holidays h
                               WHERE h.agency_id = p_agency_id AND h.is_active AND h.holiday_date = v_date);
        CONTINUE WHEN v_owner IS NOT NULL AND EXISTS (SELECT 1 FROM time_off_requests r
                               WHERE r.agency_id = p_agency_id AND r.requester_team_id = v_owner AND r.status = 'approved'
                                 AND v_date BETWEEN r.start_date AND COALESCE(r.end_date, r.start_date));
        v_st := (v_date + time '09:00') AT TIME ZONE 'America/Chicago';
        v_en := v_st + make_interval(mins => (d->>'minutes')::int);
        v_summary := 'Coaching: ' || p.first_name || ', Week ' || w.week_no;
        v_desc := (SELECT string_agg((x->>'label') || ' (' || (x->>'minutes') || ' min)', E'\n') FROM jsonb_array_elements(d->'parts') x)
                  || E'\n\nPlan: ' || v_base || '/onboarding?plan=' || p.id;
        IF p_dry_run THEN
          v_preview := v_preview || jsonb_build_object('week', w.week_no, 'date', v_date, 'start', v_st, 'end', v_en, 'summary', v_summary);
          CONTINUE;
        END IF;
        BEGIN v_res := public.calendar_create_event_now(p_agency_id, 'primary', v_summary, v_desc, v_st, v_en, CASE WHEN v_sf IS NULL THEN NULL ELSE ARRAY[v_sf] END, NULL, false, v_sf IS NOT NULL);
        EXCEPTION WHEN OTHERS THEN v_res := jsonb_build_object('ok', false, 'error', SQLERRM); END;
        e := jsonb_build_object('day', k, 'date', v_date, 'start', v_st, 'end', v_en, 'summary', v_summary,
                                'description', v_desc, 'event_id', v_res->>'event_id');
        IF COALESCE((v_res->>'ok')::boolean, false) THEN
          v_created := v_created + 1;
        ELSE
          e := e || jsonb_build_object('event_id', NULL);
          v_failed := v_failed + 1;
          INSERT INTO alerts (agency_id, alert_type, severity, title, message, module_reference, related_id)
          VALUES (p_agency_id, 'automation_failure', 'warning', 'Coaching block not placed',
                  v_summary || ' on ' || to_char(v_date, 'Dy Mon FMDD') || ' did not reach your calendar; it will retry each hour. ' ||
                  COALESCE(v_res->>'error', ''), 'onboarding', p.id);
        END IF;
        v_week := v_week || e;
      END LOOP;
      v_events := v_events || jsonb_build_object(w.week_no::text, v_week);
    END LOOP;

    IF NOT p_dry_run THEN
      UPDATE team_onboarding_plans SET coaching_events = v_events WHERE id = p.id AND coaching_events IS DISTINCT FROM v_events;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('events_created', v_created, 'events_removed', v_removed, 'failed', v_failed)
         || CASE WHEN p_dry_run THEN jsonb_build_object('would_place', v_preview) ELSE '{}'::jsonb END;
END $function$;
