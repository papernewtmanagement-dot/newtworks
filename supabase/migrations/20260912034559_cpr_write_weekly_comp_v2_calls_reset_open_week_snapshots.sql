-- Surgical patch to write_weekly_comp_v2: three insertions, applied to the live definition so
-- nothing else in a 280-line function can drift. Each replacement is asserted to hit exactly
-- one place before the new definition is executed.
--
-- What it adds: a call to reset_open_week_snapshots immediately before the crossings audit.
-- That clears this week's All-Star rows, Trailblazer rows and MVP row so the audit and the MVP
-- detection that follow rebuild them from current sales points. It is a no-op once the week is
-- frozen, so history never moves.
DO $do$
DECLARE
  d text;
  v_new_call text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'write_weekly_comp_v2';

  -- 1. declare the variable
  IF (length(d) - length(replace(d, '  v_mvp_result     jsonb;', ''))) / length('  v_mvp_result     jsonb;') <> 1 THEN
    RAISE EXCEPTION 'declare anchor did not match exactly once';
  END IF;
  d := replace(d, '  v_mvp_result     jsonb;',
                  '  v_mvp_result     jsonb;' || E'\n' || '  v_reset_result   jsonb;');

  -- 2. call it right before the crossings audit
  v_new_call :=
'  -- Peter ruling 2026-09-11: All-Star, Trailblazer and MVP compute live until the week is
  -- frozen. Clear this week snapshots first so the audit and the MVP detection below rebuild
  -- them from the sales points as they stand right now, rather than keeping what was true on
  -- Saturday night. reset_open_week_snapshots is a no-op once the week is frozen, so a week
  -- the team has already seen never moves.
  BEGIN v_reset_result := public.reset_open_week_snapshots(p_agency_id, p_week_end_date);
  EXCEPTION WHEN OTHERS THEN v_reset_result := jsonb_build_object(''error'', SQLERRM, ''sqlstate'', SQLSTATE); END;

';
  IF (length(d) - length(replace(d, '  BEGIN v_audit_result := public.audit_weekly_leaderboard_crossings(', '')))
     / length('  BEGIN v_audit_result := public.audit_weekly_leaderboard_crossings(') <> 1 THEN
    RAISE EXCEPTION 'audit anchor did not match exactly once';
  END IF;
  d := replace(d, '  BEGIN v_audit_result := public.audit_weekly_leaderboard_crossings(',
                  v_new_call || '  BEGIN v_audit_result := public.audit_weekly_leaderboard_crossings(');

  -- 3. surface the result in the return payload
  IF (length(d) - length(replace(d, '''mvp_detection_result'', v_mvp_result,', '')))
     / length('''mvp_detection_result'', v_mvp_result,') <> 1 THEN
    RAISE EXCEPTION 'return anchor did not match exactly once';
  END IF;
  d := replace(d, '''mvp_detection_result'', v_mvp_result,',
                  '''open_week_reset_result'', v_reset_result,' || E'\n    ' || '''mvp_detection_result'', v_mvp_result,');

  EXECUTE d;
END
$do$;