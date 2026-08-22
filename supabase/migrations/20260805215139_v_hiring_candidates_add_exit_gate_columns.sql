-- 2026-08-05 sweep follow-up: same class as the GMA/SJT/reliability gap —
-- the exit-gate columns (assessment_exit_gate / assessment_exit_detail /
-- assessment_exited_at) are on hiring_candidates and rendered by
-- CandidateDetail's early-exit banner, but were never projected into
-- v_hiring_candidates. An exit-gated candidate therefore showed NO exit
-- banner. Same self-splicing append, idempotent.
DO $$
DECLARE
  v_def text;
  v_new_cols text := ',
    hc.assessment_exit_gate,
    hc.assessment_exit_detail,
    hc.assessment_exited_at';
  v_anchor text := E'\n   FROM hiring_candidates hc\n     CROSS JOIN resume_w rw';
BEGIN
  v_def := pg_get_viewdef('public.v_hiring_candidates'::regclass, true);
  IF v_def ILIKE '%assessment_exit_gate%' THEN
    RAISE NOTICE 'exit-gate columns already projected, skipping';
    RETURN;
  END IF;
  IF position(v_anchor IN v_def) = 0 THEN
    RAISE EXCEPTION 'splice anchor not found in v_hiring_candidates definition';
  END IF;
  v_def := replace(v_def, v_anchor, v_new_cols || v_anchor);
  EXECUTE 'CREATE OR REPLACE VIEW public.v_hiring_candidates AS ' || v_def;
END $$;
