-- Migration 20260721224830 (mirror of applied migration)
-- The parallel Cowork migration left an ELSIF fallback where the RPC computes
-- v_na from v_best_fit_os when v_ta.assessment_nature is NULL. Frontend never uses
-- that fallback — it reads detail.assessment_nature directly from the view and shows
-- "—" when null. So the RPC's meta.matrix.nature.assessment diverged from the
-- displayed cell for John Kostov, Cassandra Alves, Stephanie Rogers, etc.
-- Fix: drop the ELSIF so RPC returns NULL exactly when view returns NULL.

DO $$
DECLARE
  fn_def text;
  before_str text := 'IF v_ta.assessment_nature IS NOT NULL THEN
    v_na := v_ta.assessment_nature::numeric;
  ELSIF v_ta.deadline_motivation IS NOT NULL THEN
    SELECT bfr.best_role, bfr.best_role_category, bfr.display_label, bfr.best_os::numeric
      INTO v_best_fit_role, v_best_role_category, v_display_label, v_best_fit_os
      FROM public.cts_best_fit_role(p_assessment_id) bfr;
    v_na := v_best_fit_os;
  END IF;';
  after_str text := 'IF v_ta.assessment_nature IS NOT NULL THEN
    v_na := v_ta.assessment_nature::numeric;
  END IF;';
BEGIN
  SELECT pg_get_functiondef('public.hiregauge_three_construct_verdict(uuid)'::regprocedure) INTO fn_def;
  IF position(before_str in fn_def) = 0 THEN
    RAISE EXCEPTION 'anchor not found in hiregauge_three_construct_verdict — has the fn changed since?';
  END IF;
  EXECUTE replace(fn_def, before_str, after_str);
END $$;
