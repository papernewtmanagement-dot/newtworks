-- compute_weekly_comp_residual_pool: the hourly base fallback counted clock hours
-- only, so a week with paid time off understated an hourly teammate's base.
-- Cassie, week ending 2026-09-12: 31.56 worked hours gave $504.96 and the 8 hours
-- of Labor Day PTO were dropped. Correct figure is $632.96.
--
-- The fallback only runs for weeks payroll has not transmitted yet. Once the real
-- paycheck lands, base already reads payroll_detail SALARY+REGULAR+HOURLY+PTO,
-- which has always included PTO. The function's own design record says PTO is
-- base-equivalent per Peter's directive; the fallback just never honored it.
--
-- Fixed by reading get_weekly_cpr_hours -- the same function the CPR Hours
-- section and the Team > Payroll tab read -- instead of a second, private copy
-- of the time-clock math. Verified beforehand that the two produce identical
-- worked hours for every week on record, so nothing but the PTO changes. The
-- COUNT(*) = 0 guard keeps the old behaviour of returning NULL when there is no
-- data at all, so a week with no hours still falls through to the design rate.
--
-- Patched in place from pg_get_functiondef so the other ~330 lines are untouched
-- byte for byte.

DO $mig$
DECLARE
  v_def text;
  v_old_a text := $a$CASE WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN (SELECT ROUND(SUM(daily_hrs) * pwp.wk_pay_rate, 2) FROM (SELECT ROUND(SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)::numeric, 2) AS daily_hrs FROM public.time_clock_entries tce WHERE tce.agency_id = p_agency_id AND tce.team_member_id = r.id AND tce.clock_out_at IS NOT NULL AND tce.clock_in_at::date >= (cw.week_end_date - 6) AND tce.clock_in_at::date <= cw.week_end_date GROUP BY DATE(tce.clock_in_at AT TIME ZONE 'America/Chicago')) daily) ELSE NULL END$a$;
  v_new_a text := $a$CASE WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN (SELECT CASE WHEN COUNT(*) = 0 THEN NULL ELSE ROUND((COALESCE(SUM(h.hours), 0) + COALESCE(SUM(h.paid_time_off_hours), 0)) * pwp.wk_pay_rate, 2) END FROM public.get_weekly_cpr_hours(p_agency_id, cw.week_end_date) h WHERE h.team_member_id = r.id) ELSE NULL END$a$;
  v_old_b text := $b$CASE WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN (SELECT ROUND(SUM(daily_hrs) * r.pay_rate, 2) FROM (SELECT ROUND(SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)::numeric, 2) AS daily_hrs FROM public.time_clock_entries tce WHERE tce.agency_id = p_agency_id AND tce.team_member_id = r.id AND tce.clock_out_at IS NOT NULL AND tce.clock_in_at::date >= (p_week_end_date - 6) AND tce.clock_in_at::date <= p_week_end_date GROUP BY DATE(tce.clock_in_at AT TIME ZONE 'America/Chicago')) daily) ELSE NULL END$b$;
  v_new_b text := $b$CASE WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN (SELECT CASE WHEN COUNT(*) = 0 THEN NULL ELSE ROUND((COALESCE(SUM(h.hours), 0) + COALESCE(SUM(h.paid_time_off_hours), 0)) * r.pay_rate, 2) END FROM public.get_weekly_cpr_hours(p_agency_id, p_week_end_date) h WHERE h.team_member_id = r.id) ELSE NULL END$b$;
  v_old_note1 text := $n1$with time-clock or design-rate fallback for current week (not yet paid). PTO included as base-equivalent per Peter directive.$n1$;
  v_new_note1 text := $n1$with get_weekly_cpr_hours (worked + PTO) or design-rate fallback for current week (not yet paid). PTO included as base-equivalent per Peter directive, in the paid line items and in the fallback alike (2026-09-15).$n1$;
  v_old_note2 text := $n2$payroll_detail SALARY+REGULAR+HOURLY+PTO (pay_date <= week_end); time-clock or design-rate fallback for current week$n2$;
  v_new_note2 text := $n2$payroll_detail SALARY+REGULAR+HOURLY+PTO (pay_date <= week_end); get_weekly_cpr_hours worked+PTO, or design-rate, fallback for current week$n2$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found';
  END IF;
  IF position(v_old_a in v_def) = 0 THEN
    RAISE EXCEPTION 'hourly base fallback (base_by_week) did not match - aborting rather than half-patching';
  END IF;
  IF position(v_old_b in v_def) = 0 THEN
    RAISE EXCEPTION 'hourly base fallback (actual_base_this_week) did not match - aborting rather than half-patching';
  END IF;

  v_def := replace(v_def, v_old_a, v_new_a);
  v_def := replace(v_def, v_old_b, v_new_b);
  -- Design-record notes: nice to have, never fatal.
  v_def := replace(v_def, v_old_note1, v_new_note1);
  v_def := replace(v_def, v_old_note2, v_new_note2);

  EXECUTE v_def;
END
$mig$;
