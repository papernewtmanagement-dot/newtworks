-- 20260915223753 dropped get_cpr_detail_sales_points_qtd on the claim that
-- get_weekly_cpr_requirements was its only caller. It was not. Three live functions
-- still called it: weekly_cpr_upsert_in_progress (the check-in path),
-- recompute_cpr_outcome and weekly_cpr_compute_outcome (the Saturday week close).
-- Point all of them at the same one resolver, get_sales_points_qtd.
DO $mig$
DECLARE
  r record;
  v_def text;
  v_new text;
  v_fixed int := 0;
  v_left int;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND pg_get_functiondef(p.oid) LIKE '%get_cpr_detail_sales_points_qtd%'
  LOOP
    v_def := pg_get_functiondef(r.oid);

    v_new := regexp_replace(
      v_def,
      '(v_[a-z_]+) := public\.get_cpr_detail_sales_points_qtd\(p_agency_id, [a-z_]+\.cycle_start, ([a-z_\.]+)\);',
      'SELECT COALESCE(SUM(g.sales_points), 0) INTO \1 FROM public.get_sales_points_qtd(p_agency_id, \2) g;',
      'g');

    v_new := replace(v_new,
      'See get_cpr_detail_sales_points_qtd.',
      'See get_sales_points_qtd - the one resolver.');

    IF v_new <> v_def THEN
      EXECUTE v_new;
      v_fixed := v_fixed + 1;
    END IF;
  END LOOP;

  IF v_fixed <> 4 THEN
    RAISE EXCEPTION 'expected 4 functions to change, changed %', v_fixed;
  END IF;

  SELECT count(*) INTO v_left
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND pg_get_functiondef(p.oid) LIKE '%public.get_cpr_detail_sales_points_qtd(%';

  IF v_left > 0 THEN
    RAISE EXCEPTION 'still % live callers of the dropped function', v_left;
  END IF;
END $mig$;
