-- Surgical removal of the remaining clock guards. Each replacement is checked;
-- if the block is not found exactly, the migration fails rather than shipping
-- a function that looks changed and is not.
DO $mig$
DECLARE d text; d2 text;
BEGIN
  -- 1. Health summary. Keep the one real precondition (nothing to summarize if
  -- no prompt went out today). Drop the clock guard and the recovery branch.
  SELECT pg_get_functiondef('public.team_health_checkin_compile(uuid,uuid)'::regprocedure) INTO d;
  d2 := replace(d,
$o$  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, 'health_eve', 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_is_within_recovery_window(v_local_time)
        AND public.team_checkin_step_completed(p_agency_id, 'health_eve', 'reminder')
        AND NOT public.team_checkin_step_completed(p_agency_id, 'health_eve', 'compile') THEN
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to compile');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;$o$,
$n$  IF NOT public.team_checkin_step_completed(p_agency_id, 'health_eve', 'reminder') THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to compile');
  END IF;$n$);
  IF d2 = d THEN RAISE EXCEPTION 'health compile: guard block not found'; END IF;
  d := d2;
  d2 := replace(d,
$o$  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_local_time := v_input_config->>'local_time';
$o$, '');
  IF d2 = d THEN RAISE EXCEPTION 'health compile: local_time read not found'; END IF;
  d := d2;
  d2 := replace(d, $o$      CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
$o$, $n$      '',
$n$);
  IF d2 = d THEN RAISE EXCEPTION 'health compile: recovery label not found'; END IF;
  d := d2;
  d := replace(d, $o$  v_input_config jsonb;
  v_local_time text;
$o$, '');
  d := replace(d, $o$  v_is_recovery boolean := false;
$o$, '');
  EXECUTE d;

  -- 2. Weekly week-close writer. The clock guard goes. The Sunday small-hours
  -- back-date stays, because it is week resolution, not a send decision: the
  -- week runs Sunday to Saturday and a late run must still close the Saturday
  -- that ended, not the week ahead.
  SELECT pg_get_functiondef('public.weekly_cpr_compute_outcome(uuid,uuid)'::regprocedure) INTO d;
  d2 := replace(d,
$o$  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    IF v_local_time = '23:59'
       AND EXTRACT(DOW FROM v_today) = 0
       AND (now() AT TIME ZONE 'America/Chicago')::time < TIME '06:00' THEN
      v_today := v_today - 1;
    ELSE
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
    END IF;
  END IF;$o$,
$n$  -- The week runs Sunday to Saturday. If a late run lands in the small hours
  -- of Sunday, close the Saturday that just ended, not the week ahead.
  IF EXTRACT(DOW FROM v_today) = 0
     AND (now() AT TIME ZONE 'America/Chicago')::time < TIME '06:00' THEN
    v_today := v_today - 1;
  END IF;$n$);
  IF d2 = d THEN RAISE EXCEPTION 'cpr outcome: guard block not found'; END IF;
  d := d2;
  d2 := replace(d,
$o$  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_local_time := v_input_config->>'local_time';

$o$, '');
  IF d2 = d THEN RAISE EXCEPTION 'cpr outcome: local_time read not found'; END IF;
  d := d2;
  d := replace(d, $o$  v_input_config jsonb;
  v_local_time text;
$o$, '');
  EXECUTE d;

  -- 3. CPR draft nudge. Its cron expression already restricts this to 6 PM
  -- Central on Saturday and Sunday. The inline hour and day re-check is a
  -- second copy of that decision.
  SELECT pg_get_functiondef('public.nudge_peter_for_cpr_drafts()'::regprocedure) INTO d;
  d2 := replace(d,
$o$  IF v_hour_ct <> 18 OR v_dow NOT IN (0, 6) THEN
    v_result := jsonb_build_object('skipped', 'wrong_dst_cron_fire', 'hour_ct', v_hour_ct, 'dow_ct', v_dow);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'success',
            'Skipped: wrong-DST cron fire (intended Sat/Sun 6 PM CT, got DOW ' || v_dow || ' hour ' || v_hour_ct || ')',
            EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

$o$, '');
  IF d2 = d THEN RAISE EXCEPTION 'cpr nudge: hour guard not found'; END IF;
  d := d2;
  d := replace(d, $o$  v_hour_ct := EXTRACT(HOUR FROM v_now_ct)::int;
$o$, '');
  d := replace(d, $o$  v_hour_ct int;
$o$, '');
  EXECUTE d;

  -- 4. CPR auto-send. Same: the cron expression already says 6 AM Central.
  SELECT pg_get_functiondef('public.try_send_weekly_cpr_recap()'::regprocedure) INTO d;
  d2 := replace(d,
$o$  IF v_hour_ct <> 6 THEN
    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
      VALUES (v_agency_id, v_recipe_id, now(), 'success',
              format('Skipped: wrong-DST cron fire (intended 6 AM CT, got hour %s)', v_hour_ct));
    END IF;
    RETURN jsonb_build_object('skipped', true, 'reason', 'wrong_dst_hour', 'hour_ct', v_hour_ct);
  END IF;

$o$, '');
  IF d2 = d THEN RAISE EXCEPTION 'cpr auto-send: hour guard not found'; END IF;
  d := d2;
  d := replace(d, $o$  v_hour_ct := EXTRACT(HOUR FROM v_now_ct)::int;
$o$, '');
  d := replace(d, $o$v_hour_ct int; $o$, '');
  EXECUTE d;
END $mig$;
