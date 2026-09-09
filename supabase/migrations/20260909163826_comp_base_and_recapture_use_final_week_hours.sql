-- Peter ruling 2026-09-09: final week of employment is prorated by hours, not workdays.
-- Two call sites in compute_weekly_comp_residual_pool move from team_week_workday_fraction
-- to team_week_base_fraction, which is workdays/5 for every normal week and hours/40 for a
-- final week. BOTH must move together: the base paid to the departing person and the
-- departure recapture held back from the pool are two halves of the same design base. If
-- only the base moved, the difference would leak into the team pool.
-- week_fraction and benefit_week_fraction are deliberately NOT changed — they count weeks
-- on the team, not dollars.
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

  -- 1) design-rate base fallback, salary and hourly branches
  v_src := public.fn_source_replace_exact(
    v_src,
    'CASE WHEN pwp.wk_pay_type = ''SALARY'' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) WHEN pwp.wk_pay_type = ''HOURLY'' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * 40 * public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) ELSE 0 END',
    'CASE WHEN pwp.wk_pay_type = ''SALARY'' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, cw.week_end_date) WHEN pwp.wk_pay_type = ''HOURLY'' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * 40 * public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, cw.week_end_date) ELSE 0 END',
    1);

  -- 2) departure recapture: the uncovered remainder of the same design base
  v_src := public.fn_source_replace_exact(
    v_src,
    '* (1 - public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date))',
    '* (1 - public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, cw.week_end_date))',
    1);

  EXECUTE v_src;
END
$do$;
