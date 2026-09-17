-- Alerts retirement, phase 2, step 1.
-- These twelve functions wrote an alert purely as a record that something
-- happened. Nobody reads alerts, and automation_run_log already carries the
-- automation side, so the write is removed and nothing replaces it.
-- Each INSERT is swapped for NULL; so the surrounding IF/ELSE shape survives.
-- The DO block fails loudly if any of them still mentions the alerts table.
DO $strip$
DECLARE
  v_names text[] := ARRAY[
    'apply_hiregauge_v2_stint1_exit_gate',
    'apply_newtworks_v2_reliability_to_candidate',
    'candidate_email_response_apply',
    'handle_assessment_invite_bounce',
    'hiregauge_fcq_norm_auto_rebuild_trg',
    'hiregauge_fcq_norm_rebuild_current_set',
    'hiregauge_gma_norm_auto_rebuild_trg',
    'hiregauge_gma_norm_rebuild_current_set',
    'notify_candidate_process_problem',
    'quarter_close_prize_cart_and_leaderboards',
    'send_mvp_prize_win_telegram',
    'trg_candidate_decline_notice'
  ];
  r record; v_def text; v_new text; v_stmt text; v_n int; v_total int := 0; v_left int;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = ANY(v_names)
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def; v_n := 0;
    LOOP
      v_stmt := substring(v_new from 'INSERT INTO\s+(?:public\.)?alerts[^;]*;');
      EXIT WHEN v_stmt IS NULL OR v_n > 12;
      v_new := replace(v_new, v_stmt, 'NULL;');
      v_n := v_n + 1;
    END LOOP;
    IF v_n > 0 THEN
      EXECUTE v_new;
      v_total := v_total + v_n;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_left
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = ANY(v_names)
    AND pg_get_functiondef(p.oid) ~* '(^|[^_a-z])(public\.)?alerts([^_a-z]|$)';

  IF v_left > 0 THEN
    RAISE EXCEPTION 'alerts retirement: % of the listed functions still reference alerts', v_left;
  END IF;
  RAISE NOTICE 'alerts retirement: % alert writes removed', v_total;
END $strip$;
