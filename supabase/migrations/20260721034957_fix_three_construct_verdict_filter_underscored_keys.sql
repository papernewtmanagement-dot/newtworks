-- Migration 20260721034957 (mirror of applied migration)
-- Fix consumers of *_competencies_adjusted output that AVG values across the jsonb.
-- Before: filter only `_meta`. After: filter all keys starting with `_` (control keys).
-- Broke because the _adjusted fns emit `_lss_deltas` alongside `_meta` — casting an object to numeric fails.
-- The two consumers are hiregauge_three_construct_verdict and *_by_role — both feed the Results matrix.

DO $$
DECLARE
  fn_def text;
  before_str text := 'WHERE e.key <> ''_meta''';
  after_str  text := 'WHERE LEFT(e.key, 1) <> ''_''';
BEGIN
  SELECT pg_get_functiondef('public.hiregauge_three_construct_verdict(uuid)'::regprocedure) INTO fn_def;
  IF position(before_str in fn_def) = 0 THEN
    RAISE EXCEPTION 'anchor not found in hiregauge_three_construct_verdict';
  END IF;
  EXECUTE replace(fn_def, before_str, after_str);

  SELECT pg_get_functiondef('public.hiregauge_three_construct_verdict_by_role(uuid)'::regprocedure) INTO fn_def;
  IF position(before_str in fn_def) = 0 THEN
    RAISE EXCEPTION 'anchor not found in hiregauge_three_construct_verdict_by_role';
  END IF;
  EXECUTE replace(fn_def, before_str, after_str);
END $$;
