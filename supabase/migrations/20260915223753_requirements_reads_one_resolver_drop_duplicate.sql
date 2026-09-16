-- get_cpr_detail_sales_points_qtd was a second copy of the same rule: it read the raw
-- override column only, so it never saw the freeze, never saw Production, and had no
-- self-reported fallback. Its only caller was get_weekly_cpr_requirements. Patch that
-- one line in place and drop the duplicate. One job, one function.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_weekly_cpr_requirements';

  IF position('get_cpr_detail_sales_points_qtd' in v_def) = 0 THEN
    RAISE EXCEPTION 'expected call not found - another thread changed this function, stopping';
  END IF;

  v_def := replace(v_def,
    'v_sp_qtd := public.get_cpr_detail_sales_points_qtd(p_agency_id, v_cyc.cycle_start, p_week_ending_date);',
    'SELECT COALESCE(SUM(g.sales_points), 0) INTO v_sp_qtd FROM public.get_sales_points_qtd(p_agency_id, p_week_ending_date) g;');

  EXECUTE v_def;
END $mig$;

DROP FUNCTION IF EXISTS public.get_cpr_detail_sales_points_qtd(uuid, date, date);
