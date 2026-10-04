
ALTER TABLE public.team_onboarding_plans ADD COLUMN IF NOT EXISTS coaching_events jsonb NOT NULL DEFAULT '{}'::jsonb;
COMMENT ON COLUMN public.team_onboarding_plans.coaching_events IS 'Peter''s coaching blocks placed on his Google Calendar, by plan week: {"1": [{day, date, start, end, summary, description, event_id}]}. Written by onboarding_coaching_blocks_sync. A week key present means that week was handled.';

INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description)
SELECT a.id, 'onboarding_owner_vacation_weeks', '13,26', 'text', 'Onboarding weeks Peter is on vacation: no coaching blocks those weeks (Peter 2026-10-03).'
FROM public.agency a WHERE a.id = '126794dd-25ff-47d2-a436-724499733365'
  AND NOT EXISTS (SELECT 1 FROM public.settings s WHERE s.agency_id = a.id AND s.setting_key = 'onboarding_owner_vacation_weeks');

CREATE OR REPLACE FUNCTION public.onboarding_coaching_blocks_plan(p_plan_id uuid, p_week_no integer)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Peter's coaching time for one week of a hire's plan, read off that week's own cards (Peter 2026-10-04,
-- plan approved "defaults"). A changed card changes its blocks.
--   Orientation card in the week -> day 1, 120 min (orientation talk + Staff Agreement Assessment with Peter).
--   Study day Mon-Thu whose Explain line says coverages -> 30 min, Peter teaches the coverages. Friday is their recap.
--   Practice day with a new role play (a 🎭 x3 line that isn't an objections line) -> 60 min in Weeks 1-4,
--     30 min in Weeks 5-12, from Week 14 on 30 min on the week's first such day only.
--   Owner vacation week (setting onboarding_owner_vacation_weeks) -> none; a "... with Peter" item in it moves to
--     day 1 of the next week, 30 min.
-- Returns [{day, minutes, parts:[{label, minutes}]}]; day 1-5 = the Monday..Friday groups. The sync sets dates.
DECLARE
  v_agency uuid; v_vac int[];
  v_parts jsonb[] := ARRAY['[]','[]','[]','[]','[]']::jsonb[];
  v_names text[] := ARRAY['Monday','Tuesday','Wednesday','Thursday','Friday'];
  v_sub jsonb; g jsonb; v_i int; v_items text[]; v_pieces text[]; v_first boolean := true; v_txt text;
  v_out jsonb := '[]'::jsonb;
BEGIN
  SELECT agency_id INTO v_agency FROM team_onboarding_plans WHERE id = p_plan_id;
  SELECT COALESCE(array_agg(btrim(x)::int), ARRAY[]::int[]) INTO v_vac
    FROM unnest(string_to_array(COALESCE(public.get_setting(v_agency, 'onboarding_owner_vacation_weeks'), ''), ',')) x
   WHERE btrim(x) ~ '^\d+$';
  IF p_week_no = ANY(v_vac) THEN RETURN '[]'::jsonb; END IF;

  IF EXISTS (SELECT 1 FROM team_onboarding_steps WHERE plan_id = p_plan_id AND week_no = p_week_no AND title = 'Orientation') THEN
    v_parts[1] := v_parts[1] || jsonb_build_object('label', 'Orientation', 'minutes', 120);
  END IF;

  IF (p_week_no - 1) = ANY(v_vac) THEN
    SELECT (regexp_match(substeps::text, '([A-Z][^".]*?) with Peter'))[1] INTO v_txt
      FROM team_onboarding_steps
     WHERE plan_id = p_plan_id AND week_no = p_week_no - 1 AND substeps::text LIKE '% with Peter%' LIMIT 1;
    IF v_txt IS NOT NULL THEN
      v_parts[1] := v_parts[1] || jsonb_build_object('label', v_txt, 'minutes', 30);
    END IF;
  END IF;

  SELECT substeps INTO v_sub FROM team_onboarding_steps WHERE plan_id = p_plan_id AND week_no = p_week_no AND title = 'Study' LIMIT 1;
  FOR g IN SELECT x FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_sub) = 'array' THEN v_sub ELSE '[]'::jsonb END) x LOOP
    CONTINUE WHEN jsonb_typeof(g) <> 'object';
    v_i := array_position(v_names, g->>'group');
    CONTINUE WHEN v_i IS NULL OR v_i > 4;
    SELECT array_agg(replace(t, chr(8203), '')) INTO v_items FROM jsonb_array_elements_text(COALESCE(g->'items', '[]'::jsonb)) t;
    CONTINUE WHEN v_items IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(v_items) t WHERE t LIKE 'Explain today''s coverages%');
    v_parts[v_i] := v_parts[v_i] || jsonb_build_object('label', 'Coverages: ' ||
      COALESCE((SELECT string_agg(regexp_replace(t, '\[([^]]*)\]\([^)]*\)', '\1', 'g'), ', ')
                  FROM unnest(v_items) t WHERE t NOT LIKE 'Explain%'), 'today''s coverages'), 'minutes', 30);
  END LOOP;

  SELECT substeps INTO v_sub FROM team_onboarding_steps WHERE plan_id = p_plan_id AND week_no = p_week_no AND title = 'Practice' LIMIT 1;
  FOR g IN SELECT x FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_sub) = 'array' THEN v_sub ELSE '[]'::jsonb END) x LOOP
    CONTINUE WHEN jsonb_typeof(g) <> 'object';
    v_i := array_position(v_names, g->>'group');
    CONTINUE WHEN v_i IS NULL;
    SELECT array_agg(regexp_replace(regexp_replace(replace(t, chr(8203), ''), '^🎭\s*', ''), '\s*x3\M.*$', ''))
      INTO v_pieces FROM jsonb_array_elements_text(COALESCE(g->'items', '[]'::jsonb)) t
     WHERE left(t, 1) = '🎭' AND t ~ ' x3\M' AND t !~* 'objections';
    CONTINUE WHEN v_pieces IS NULL;
    CONTINUE WHEN p_week_no >= 14 AND NOT v_first;
    v_first := false;
    v_parts[v_i] := v_parts[v_i] || jsonb_build_object('label', 'Script: ' || array_to_string(v_pieces, ' + '),
      'minutes', CASE WHEN p_week_no <= 4 THEN 60 ELSE 30 END);
  END LOOP;

  FOR v_i IN 1..5 LOOP
    CONTINUE WHEN jsonb_array_length(v_parts[v_i]) = 0;
    v_out := v_out || jsonb_build_object('day', v_i, 'parts', v_parts[v_i],
      'minutes', (SELECT sum((x->>'minutes')::int) FROM jsonb_array_elements(v_parts[v_i]) x));
  END LOOP;
  RETURN v_out;
END $fn$;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_event_remove(p_agency_id uuid, p_plan_id uuid, p_entry jsonb)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Takes one coaching block off Peter's calendar. A failure leaves an alert to remove it by hand.
DECLARE v_res jsonb;
BEGIN
  IF p_entry->>'event_id' IS NULL THEN RETURN true; END IF;
  BEGIN v_res := public.calendar_delete_event_now(p_agency_id, 'primary', p_entry->>'event_id');
  EXCEPTION WHEN OTHERS THEN v_res := jsonb_build_object('ok', false, 'error', SQLERRM); END;
  IF COALESCE((v_res->>'ok')::boolean, false) THEN RETURN true; END IF;
  INSERT INTO alerts (agency_id, alert_type, severity, title, message, module_reference, related_id)
  VALUES (p_agency_id, 'automation_failure', 'warning', 'Coaching block not removed',
          'Take it off your calendar by hand: ' || COALESCE(p_entry->>'summary', 'coaching block') || ' on ' ||
          COALESCE(to_char((p_entry->>'date')::date, 'Dy Mon FMDD'), '?') || '. ' || COALESCE(v_res->>'error', ''),
          'onboarding', p_plan_id);
  RETURN false;
END $fn$;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_blocks_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_dry_run boolean DEFAULT false, p_now timestamptz DEFAULT now())
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Places Peter's coaching blocks (onboarding_coaching_blocks_plan) on his Google Calendar when each week of a hire's
-- plan opens. Called from onboarding_open_step_notices on the hourly tick. Peter's calendar only: no attendees, no
-- emails. One event per day at 9:00 Central. Skips company holidays and Peter's approved time off. A week that opens
-- early first takes down earlier weeks' blocks still ahead. A block that failed to place is retried while still ahead.
-- p_dry_run returns what it would place and writes nothing; p_now lets a dry run pretend it is another time.
DECLARE
  p record; w record; d jsonb; e jsonb; k int; i int;
  v_local timestamp := p_now AT TIME ZONE 'America/Chicago';
  v_today date := (p_now AT TIME ZONE 'America/Chicago')::date;
  v_owner uuid; v_base text; v_events jsonb; v_week jsonb; v_kept jsonb; v_res jsonb; v_key text;
  v_opens date; v_next date; v_start date; v_date date; v_st timestamptz; v_en timestamptz;
  v_summary text; v_desc text; v_created int := 0; v_removed int := 0; v_failed int := 0; v_preview jsonb := '[]'::jsonb;
BEGIN
  SELECT id INTO v_owner FROM team WHERE agency_id = p_agency_id AND role_level = 'Owner' ORDER BY created_at LIMIT 1;
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
                    (e->>'start')::timestamptz, (e->>'end')::timestamptz, NULL, NULL, false, false);
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
        BEGIN v_res := public.calendar_create_event_now(p_agency_id, 'primary', v_summary, v_desc, v_st, v_en, NULL, NULL, false, false);
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
END $fn$;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_blocks_cleanup()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- A deleted plan (termination deletes it) takes its coaching blocks still ahead off Peter's calendar.
DECLARE e jsonb;
BEGIN
  FOR e IN SELECT x FROM jsonb_each(COALESCE(OLD.coaching_events, '{}'::jsonb)) w, jsonb_array_elements(w.value) x LOOP
    CONTINUE WHEN (e->>'start')::timestamptz <= now();
    PERFORM public.onboarding_coaching_event_remove(OLD.agency_id, OLD.id, e);
  END LOOP;
  RETURN OLD;
END $fn$;

DROP TRIGGER IF EXISTS trg_onboarding_coaching_blocks_cleanup ON public.team_onboarding_plans;
CREATE TRIGGER trg_onboarding_coaching_blocks_cleanup BEFORE DELETE ON public.team_onboarding_plans
  FOR EACH ROW EXECUTE FUNCTION public.onboarding_coaching_blocks_cleanup();

CREATE OR REPLACE FUNCTION public.onboarding_open_step_notices(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid, p_recipe_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  g        record;
  v_titles text[];
  v_ids    uuid[];
  v_tg     text;
  v_html   text;
  v_line   text;
  v_where  text;
  v_base   text;
  v_link   text;
  v_people int := 0;
  v_steps  int := 0;
  v_emails int := 0;
BEGIN
  PERFORM public.onboarding_sync_reference_steps(p_agency_id);
  PERFORM public.onboarding_team_card_notices(p_agency_id);
  PERFORM public.onboarding_sync_form_steps(NULL);
  -- Peter's coaching blocks for each hire week that just opened (Peter 2026-10-04). A failure alerts and never stops the notices.
  BEGIN
    PERFORM public.onboarding_coaching_blocks_sync(p_agency_id);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference)
    VALUES (p_agency_id, 'automation_failure', 'warning', 'Coaching blocks sync failed', SQLERRM, 'onboarding');
  END;

  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');

  FOR g IN
    WITH open_steps AS (
      SELECT s.id, s.title, s.assigned_to, s.assign_role_category, s.plan_id, p.start_date,
             p.team_member_id AS subject_tm,
             COALESCE(
               NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name, '')), ''),
               NULLIF(TRIM(COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '')), ''),
               c.candidate_name, 'the new hire') AS subject_name
      FROM public.team_onboarding_steps s
      JOIN public.team_onboarding_plans p ON p.id = s.plan_id
      LEFT JOIN public.team t ON t.id = p.team_member_id
      LEFT JOIN public.hiring_candidates c ON c.id = p.candidate_id
      WHERE p.agency_id = p_agency_id
        AND p.status = 'active'
        AND (s.assigned_to IS NOT NULL OR s.assign_role_category IS NOT NULL)
        AND s.opened_notified_at IS NULL
        AND public.onboarding_step_is_open(s.id)
    ),
    recipients AS (
      SELECT o.id, o.title, o.plan_id, o.start_date, o.subject_name, o.assigned_to AS recipient
      FROM open_steps o
      WHERE o.assigned_to IS NOT NULL
      UNION
      SELECT o.id, o.title, o.plan_id, o.start_date, o.subject_name, x.id
      FROM open_steps o
      JOIN public.team x
        ON x.agency_id = p_agency_id
       AND x.role_category = o.assign_role_category
       AND x.is_active IS TRUE AND x.archived_at IS NULL
       AND COALESCE(x.is_test_user, false) = false
       AND x.id IS DISTINCT FROM o.subject_tm
      WHERE o.assign_role_category IS NOT NULL
    )
    SELECT r.recipient, r.plan_id, r.subject_name, r.start_date,
           COALESCE(NULLIF(TRIM(COALESCE(tm.nickname, tm.first_name)), ''), 'there') AS first_name,
           COALESCE(NULLIF(tm.email_personal, ''), NULLIF(tm.email_sf, '')) AS email,
           EXISTS (SELECT 1 FROM public.users u
                   WHERE u.team_member_id = tm.id AND public.user_gets_tasks(u.id)) AS gets_tasks,
           array_agg(r.title ORDER BY r.title) AS titles,
           array_agg(r.id) AS step_ids
    FROM recipients r
    JOIN public.team tm ON tm.id = r.recipient
    GROUP BY r.recipient, r.plan_id, r.subject_name, r.start_date, tm.id,
             tm.nickname, tm.first_name, tm.email_personal, tm.email_sf
  LOOP
    v_titles := g.titles;
    v_ids    := g.step_ids;
    v_link   := v_base || '/onboarding?plan=' || g.plan_id::text;
    v_where  := CASE WHEN g.gets_tasks THEN 'They are on your task list in Newtworks'
                     ELSE 'Handle them on the Development tab in Newtworks' END;

    v_line := CASE WHEN array_length(v_titles, 1) = 1
                   THEN '1 onboarding step is ready for you'
                   ELSE array_length(v_titles, 1)::text || ' onboarding steps are ready for you' END;

    v_tg := '<b>' || g.first_name || ' — ' || v_line || '</b>' || E'\n' ||
            'Onboarding for ' || g.subject_name ||
            CASE WHEN g.start_date IS NULL THEN ''
                 ELSE ', starting ' || to_char(g.start_date, 'Dy Mon FMDD') END || E'\n\n' ||
            (SELECT string_agg('• ' || t, E'\n') FROM unnest(v_titles) t) || E'\n\n' ||
            v_where || ': ' || v_link;

    PERFORM public.telegram_send('admin', v_tg, p_agency_id, 'HTML');

    IF g.email IS NOT NULL THEN
      v_html := '<p>Hi ' || g.first_name || ',</p>' ||
                '<p>' || v_line || ' on the onboarding schedule for <b>' || g.subject_name || '</b>' ||
                CASE WHEN g.start_date IS NULL THEN ''
                     ELSE ', who starts ' || to_char(g.start_date, 'Dy Mon FMDD') END || '.</p><ul>' ||
                (SELECT string_agg('<li>' || t || '</li>', '') FROM unnest(v_titles) t) ||
                '</ul>' ||
                CASE WHEN g.gets_tasks
                     THEN '<p>They are on your task list, and the whole checklist is here: '
                     ELSE '<p>Handle them on the Development tab in Newtworks and tick each one off when it is done: '
                END ||
                '<a href="' || v_link || '">Open ' || g.subject_name || '''s onboarding in Newtworks</a></p>' ||
                '<p>Nothing else on that checklist needs you yet. Anything dated later will turn up in another note when it does.</p>';

      PERFORM public.composio_send_email(
        p_agency_id, g.email,
        g.subject_name || ' onboarding — ' || v_line, v_html);
      v_emails := v_emails + 1;
    END IF;

    UPDATE public.team_onboarding_steps
    SET opened_notified_at = now()
    WHERE id = ANY (v_ids);

    v_people := v_people + 1;
    v_steps  := v_steps + array_length(v_titles, 1);
  END LOOP;

  RETURN jsonb_build_object('people', v_people, 'steps', v_steps, 'emails', v_emails);
END;
$function$;
