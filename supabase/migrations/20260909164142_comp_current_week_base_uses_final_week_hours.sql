-- Third and final call site. The actual_base_this_week CTE is what feeds
-- weekly_base_salary, which is the base figure written to the CPR row and shown on the
-- page. Migration 20260909170545 moved base_by_week (the cycle-history ledger) and the
-- departure recapture, but missed this one, so the page still showed the workday-based
-- figure. Same substitution: team_week_base_fraction is workdays/5 in every normal week
-- and hours/40 in a final week.
DO $do$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found';
  END IF;

  v_src := public.fn_source_replace_exact(
    v_src,
    'CASE WHEN r.pay_type = ''SALARY'' AND r.pay_rate IS NOT NULL THEN r.pay_rate * public.team_week_workday_fraction(r.start_date, r.end_date, p_week_end_date) WHEN r.pay_type = ''HOURLY'' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * public.team_week_workday_fraction(r.start_date, r.end_date, p_week_end_date) ELSE 0 END) AS actual_base_paid',
    'CASE WHEN r.pay_type = ''SALARY'' AND r.pay_rate IS NOT NULL THEN r.pay_rate * public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, p_week_end_date) WHEN r.pay_type = ''HOURLY'' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, p_week_end_date) ELSE 0 END) AS actual_base_paid',
    1);

  EXECUTE v_src;
END
$do$;
