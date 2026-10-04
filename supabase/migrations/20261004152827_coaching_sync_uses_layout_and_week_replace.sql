CREATE OR REPLACE FUNCTION public.onboarding_coaching_blocks_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid, p_dry_run boolean DEFAULT false, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Places Peter's coaching blocks (onboarding_coaching_blocks_plan) on his Google Calendar when each week of a hire's
-- plan opens. Called from onboarding_open_step_notices on the hourly tick. Invites Peter's State Farm email and every
-- active new hire's State Farm email (team.email_sf, never a personal email); all hires attend all trainings and
-- future blocks pick up a new hire's invite (Peter 2026-10-04).
-- Never double-books (Peter 2026-10-04): where blocks go is onboarding_coaching_week_layout (open time 9:00-17:00,
-- never on a calendar event or an interview time, booked or open; split only when needed; time that doesn't fit rolls to
-- the next working day). Who is invited is onboarding_coaching_invitees (hires only while the setting allows it). If the calendar can't be read or a block can't be created, that week's blocks from this
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
  v_summary text; v_desc text; v_abort boolean; v_lay jsonb; v_txt jsonb; v_created int := 0; v_removed int := 0; v_failed int := 0; v_preview jsonb := '[]'::jsonb;
BEGIN
  SELECT id, NULLIF(btrim(email_sf), '') INTO v_owner, v_owner_sf FROM team
   WHERE agency_id = p_agency_id AND role_level = 'Owner' ORDER BY created_at LIMIT 1;
  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');
  -- Hires are invited only while setting onboarding_coaching_invite_hires = 'true' (Peter 2026-10-04: stop inviting Bryson for now).
  v_att := public.onboarding_coaching_invitees(p_agency_id);
  FOR p IN
    SELECT pl.id, pl.start_date, COALESCE(pl.coaching_events, '{}'::jsonb) AS events, NULLIF(btrim(t.email_sf), '') AS hire_sf,
           COALESCE(NULLIF(btrim(COALESCE(t.nickname, t.first_name)), ''), NULLIF(btrim(c.first_name), ''), 'new hire') AS first_name
      FROM team_onboarding_plans pl
      LEFT JOIN team t ON t.id = pl.team_member_id
      LEFT JOIN hiring_candidates c ON c.id = pl.candidate_id
     WHERE pl.agency_id = p_agency_id AND pl.status = 'active' AND pl.start_date IS NOT NULL
  LOOP
    v_events := p.events;
    -- every block still ahead carries the current invite list
    IF NOT p_dry_run THEN
      FOR v_key IN SELECT key FROM jsonb_each(v_events) LOOP
        v_kept := '[]'::jsonb;
        FOR e IN SELECT x FROM jsonb_array_elements(v_events->v_key) x LOOP
          IF e->>'event_id' IS NOT NULL AND (e->>'start')::timestamptz > p_now AND COALESCE(e->'attendees', '[]'::jsonb) IS DISTINCT FROM to_jsonb(v_att) THEN
            v_res := public.calendar_patch_event_now(p_agency_id, 'primary', e->>'event_id', (e->>'start')::timestamptz, (e->>'end')::timestamptz,
                       e->>'summary', e->>'description', NULL, v_att, 'all');
            IF COALESCE((v_res->>'ok')::boolean, false) THEN e := e || jsonb_build_object('attendees', to_jsonb(v_att)); END IF;
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

      v_lay := public.onboarding_coaching_week_layout(p.id, w.week_no, v_start, v_next, v_start, '{}'::text[]);
      v_week := '[]'::jsonb; v_abort := v_lay IS NULL; v_res := NULL;
      IF NOT v_abort THEN
        FOR d IN SELECT x FROM jsonb_array_elements(v_lay->'pieces') x LOOP
          v_txt := public.onboarding_coaching_event_text(p.id, w.week_no, d->'lines');
          IF p_dry_run THEN v_preview := v_preview || (d || jsonb_build_object('week', w.week_no)); CONTINUE; END IF;
          BEGIN v_res := public.calendar_create_event_now(p_agency_id, 'primary', v_txt->>'summary', v_txt->>'description',
                  (d->>'start')::timestamptz, (d->>'end')::timestamptz,
                  CASE WHEN cardinality(v_att) = 0 THEN NULL ELSE v_att END, NULL, false, cardinality(v_att) > 0);
          EXCEPTION WHEN OTHERS THEN v_res := jsonb_build_object('ok', false, 'error', SQLERRM); END;
          IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN v_abort := true; EXIT; END IF;
          v_week := v_week || jsonb_build_object('day', d->'day', 'date', d->'date', 'start', d->'start', 'end', d->'end',
                      'summary', v_txt->>'summary', 'description', v_txt->>'description', 'event_id', v_res->>'event_id', 'attendees', to_jsonb(v_att));
          v_created := v_created + 1;
        END LOOP;
      END IF;
      IF NOT v_abort AND COALESCE((v_lay->>'unplaced_minutes')::int, 0) > 0 THEN
        IF p_dry_run THEN
          v_preview := v_preview || jsonb_build_object('week', w.week_no, 'did_not_fit_minutes', (v_lay->>'unplaced_minutes')::int);
        ELSE
          INSERT INTO alerts (agency_id, alert_type, severity, title, message, module_reference, related_id)
          VALUES (p_agency_id, 'automation_failure', 'warning', 'Coaching time did not fit',
                  (v_lay->>'unplaced_minutes') || ' minutes of ' || p.first_name || $$'s Week $$ || w.week_no ||
                  ' coaching found no open time between 9 and 5 that week.', 'onboarding', p.id);
        END IF;
      END IF;

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
END $function$
;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_week_replace(p_plan_id uuid, p_week_no integer, p_dry_run boolean DEFAULT true,
  p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
-- Re-places one week of coaching blocks already on Peter's calendar, for when his calendar or the placing rules change.
-- Same placing as a newly opened week (onboarding_coaching_week_layout), keeping the week's original day 1. Blocks
-- still ahead move in place, in time order, so whoever is invited (onboarding_coaching_invitees) gets one update rather
-- than a cancelation and a new invite; extra pieces are created, leftover blocks taken down. Past blocks stay.
-- p_dry_run (the default) returns the new layout and writes nothing.
DECLARE
  v_agency uuid; v_events jsonb; v_all jsonb; v_future jsonb; v_past jsonb; v_first date; v_next date; v_place date;
  v_local timestamp := p_now AT TIME ZONE 'America/Chicago'; v_lay jsonb; v_att text[]; v_ids text[];
  i int; n_f int; n_p int; f jsonb; pc jsonb; v_txt jsonb; v_res jsonb; v_new jsonb := '[]'::jsonb;
  v_moved int := 0; v_created int := 0; v_removed int := 0; v_failed int := 0;
BEGIN
  SELECT agency_id, COALESCE(coaching_events, '{}'::jsonb) INTO v_agency, v_events FROM team_onboarding_plans WHERE id = p_plan_id;
  v_all := COALESCE(v_events->(p_week_no::text), '[]'::jsonb);
  IF jsonb_array_length(v_all) = 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'that week has no blocks on the calendar'); END IF;
  SELECT COALESCE(jsonb_agg(x ORDER BY (x->>'start')::timestamptz), '[]'::jsonb) INTO v_future
    FROM jsonb_array_elements(v_all) x WHERE (x->>'start')::timestamptz > p_now;
  SELECT COALESCE(jsonb_agg(x ORDER BY (x->>'start')::timestamptz), '[]'::jsonb) INTO v_past
    FROM jsonb_array_elements(v_all) x WHERE (x->>'start')::timestamptz <= p_now;
  SELECT min((x->>'date')::date) INTO v_first FROM jsonb_array_elements(v_all) x;
  SELECT public.onboarding_phase_opens_on(v_agency, min(s.phase), pl.start_date) INTO v_next
    FROM team_onboarding_steps s JOIN team_onboarding_plans pl ON pl.id = s.plan_id
   WHERE s.plan_id = p_plan_id AND s.week_no = p_week_no + 1 GROUP BY pl.start_date;
  v_place := CASE WHEN v_local::time < time '09:00' THEN v_local::date ELSE v_local::date + 1 END;
  v_ids := ARRAY(SELECT x->>'event_id' FROM jsonb_array_elements(v_future) x WHERE x->>'event_id' IS NOT NULL);
  v_lay := public.onboarding_coaching_week_layout(p_plan_id, p_week_no, v_first, v_next, GREATEST(v_first, v_place), v_ids);
  IF v_lay IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'the calendar could not be read'); END IF;
  IF p_dry_run THEN
    RETURN jsonb_build_object('ok', true, 'dry_run', true, 'blocks_to_move', jsonb_array_length(v_future), 'layout', v_lay);
  END IF;

  v_att := public.onboarding_coaching_invitees(v_agency);
  n_f := jsonb_array_length(v_future); n_p := jsonb_array_length(v_lay->'pieces');
  FOR i IN 0..GREATEST(n_f, n_p) - 1 LOOP
    f := v_future->i; pc := v_lay->'pieces'->i;
    IF pc IS NULL THEN
      IF public.onboarding_coaching_event_remove(v_agency, p_plan_id, f) THEN v_removed := v_removed + 1;
      ELSE v_failed := v_failed + 1; v_new := v_new || f; END IF;
      CONTINUE;
    END IF;
    v_txt := public.onboarding_coaching_event_text(p_plan_id, p_week_no, pc->'lines');
    IF f IS NOT NULL AND f->>'event_id' IS NOT NULL THEN
      BEGIN v_res := public.calendar_patch_event_now(v_agency, 'primary', f->>'event_id', (pc->>'start')::timestamptz, (pc->>'end')::timestamptz,
              v_txt->>'summary', v_txt->>'description', NULL, CASE WHEN cardinality(v_att) = 0 THEN NULL ELSE v_att END, 'all');
      EXCEPTION WHEN OTHERS THEN v_res := jsonb_build_object('ok', false, 'error', SQLERRM); END;
      IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN v_failed := v_failed + 1; v_new := v_new || f; CONTINUE; END IF;
      v_moved := v_moved + 1;
    ELSE
      BEGIN v_res := public.calendar_create_event_now(v_agency, 'primary', v_txt->>'summary', v_txt->>'description',
              (pc->>'start')::timestamptz, (pc->>'end')::timestamptz, CASE WHEN cardinality(v_att) = 0 THEN NULL ELSE v_att END,
              NULL, false, cardinality(v_att) > 0);
      EXCEPTION WHEN OTHERS THEN v_res := jsonb_build_object('ok', false, 'error', SQLERRM); END;
      IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN v_failed := v_failed + 1; CONTINUE; END IF;
      v_created := v_created + 1;
    END IF;
    v_new := v_new || jsonb_build_object('day', pc->'day', 'date', pc->'date', 'start', pc->'start', 'end', pc->'end',
               'summary', v_txt->>'summary', 'description', v_txt->>'description', 'event_id', v_res->>'event_id', 'attendees', to_jsonb(v_att));
  END LOOP;

  UPDATE team_onboarding_plans SET coaching_events = jsonb_set(COALESCE(coaching_events, '{}'::jsonb), ARRAY[p_week_no::text], v_past || v_new)
   WHERE id = p_plan_id;
  IF v_failed > 0 OR COALESCE((v_lay->>'unplaced_minutes')::int, 0) > 0 THEN
    INSERT INTO alerts (agency_id, alert_type, severity, title, message, module_reference, related_id)
    VALUES (v_agency, 'automation_failure', 'warning', 'Coaching blocks not fully re-placed',
            'Week ' || p_week_no || ': ' || v_failed || ' calendar changes failed, ' || COALESCE(v_lay->>'unplaced_minutes', '0') ||
            ' minutes found no open time.', 'onboarding', p_plan_id);
  END IF;
  RETURN jsonb_build_object('ok', v_failed = 0, 'moved', v_moved, 'created', v_created, 'removed', v_removed, 'failed', v_failed,
                            'unplaced_minutes', COALESCE((v_lay->>'unplaced_minutes')::int, 0));
END $function$;

