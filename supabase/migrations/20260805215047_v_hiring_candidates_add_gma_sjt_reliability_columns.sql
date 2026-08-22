-- 2026-08-05: CandidateDetail reads v_hiring_candidates, but 17 columns the
-- page's GMA / SJT / reliability / impression-management sections render were
-- added to hiring_candidates AFTER the view's last full rebuild and never
-- projected — so finalize wrote the data and the page showed blanks (Peter's
-- self-test made it visible). Appends the missing columns at the END of the
-- select list, preserving every existing column's name/order/type per the
-- view's own ordinal-contract convention. Self-splicing via pg_get_viewdef
-- so the current definition is never hand-transcribed; idempotent (skips if
-- the columns are already projected).
DO $$
DECLARE
  v_def text;
  v_new_cols text := ',
    hc.gma_pattern_accuracy,
    hc.gma_numerical_accuracy,
    hc.gma_deductive_accuracy,
    hc.gma_verbal_accuracy,
    hc.gma_total_accuracy,
    hc.gma_pattern_speed_seconds,
    hc.gma_numerical_speed_seconds,
    hc.gma_deductive_speed_seconds,
    hc.gma_verbal_speed_seconds,
    hc.sjt_score,
    hc.sjt_topic_detail,
    hc.reliability_detail,
    hc.impression_management,
    hc.impression_management_band,
    hc.impression_management_detail,
    hc.assessment_started_at,
    hc.assessment_completed_at';
  v_anchor text := E'\n   FROM hiring_candidates hc\n     CROSS JOIN resume_w rw';
BEGIN
  v_def := pg_get_viewdef('public.v_hiring_candidates'::regclass, true);
  IF v_def ILIKE '%gma_total_accuracy%' THEN
    RAISE NOTICE 'columns already projected, skipping';
    RETURN;
  END IF;
  IF position(v_anchor IN v_def) = 0 THEN
    RAISE EXCEPTION 'splice anchor not found in v_hiring_candidates definition';
  END IF;
  v_def := replace(v_def, v_anchor, v_new_cols || v_anchor);
  EXECUTE 'CREATE OR REPLACE VIEW public.v_hiring_candidates AS ' || v_def;
END $$;
