-- Payroll arrival is now the freeze point.
--
-- When payroll detail lands for a pay period, this locks that week in
-- weekly_pool_lock (same shape and lock_source the existing rows use) and writes
-- the commission projection row from the paid numbers. After that the week does
-- not recalculate.
--
-- The running quarter figure passed to the projection is the sum of
-- bonus_actually_paid across the locked weeks of that quarter, which is team bonus
-- actually paid quarter to date.
--
-- Existing lock rows are never overwritten, so manual notes and corrections stand.

CREATE OR REPLACE FUNCTION public.tg_lock_week_on_payroll_paid()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  r            record;
  v_basis      jsonb;
  v_annual     numeric;
  v_pct        numeric;
  v_env        numeric;
  v_paid       numeric;
  v_cum        numeric;
  v_cycle_start date;
BEGIN
  FOR r IN
    SELECT DISTINCT pd.agency_id AS agency_id, pr.pay_period_end AS wk
    FROM newrows pd
    JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id
    WHERE pd.agency_id IS NOT NULL AND pr.pay_period_end IS NOT NULL
  LOOP
    SELECT COALESCE(SUM((kv.value->>'period')::numeric), 0)
      INTO v_paid
    FROM public.payroll_runs pr2
    JOIN public.payroll_detail pd2 ON pd2.payroll_run_id = pr2.id
    CROSS JOIN LATERAL jsonb_each(COALESCE(pd2.raw_earnings->'items', '{}'::jsonb)) kv
    WHERE pd2.agency_id = r.agency_id
      AND pr2.pay_period_end = r.wk
      AND kv.key ILIKE '%Team%';

    v_basis  := public.compute_pool_basis_and_envelope(r.agency_id, r.wk);
    v_annual := COALESCE(NULLIF(v_basis->'basis'->>'total_basis_annual','')::numeric, 0);
    v_pct    := COALESCE(NULLIF(v_basis->'schedule'->>'pool_pct','')::numeric, 0);
    v_env    := (v_annual * v_pct / 100.0) / 52.0;

    INSERT INTO public.weekly_pool_lock (
      agency_id, week_end_date, annual_basis_locked, pool_pct_locked,
      weekly_envelope_locked, bonus_actually_paid, lock_source, locked_at, notes
    ) VALUES (
      r.agency_id, r.wk, v_annual, v_pct, v_env, v_paid,
      'payroll_paid', now(), 'auto-locked on payroll arrival'
    )
    ON CONFLICT (agency_id, week_end_date) DO NOTHING;

    SELECT cycle_start INTO v_cycle_start
    FROM public.current_cycle_info(r.agency_id, r.wk);

    IF v_cycle_start IS NOT NULL THEN
      SELECT COALESCE(SUM(l.bonus_actually_paid), 0)
        INTO v_cum
      FROM public.weekly_pool_lock l
      WHERE l.agency_id = r.agency_id
        AND l.week_end_date >= v_cycle_start
        AND l.week_end_date <= r.wk;

      PERFORM public.write_commission_projection(r.agency_id, r.wk, v_cum);
    END IF;
  END LOOP;

  RETURN NULL;
END
$fn$;

DROP TRIGGER IF EXISTS trg_lock_week_on_payroll_paid ON public.payroll_detail;
CREATE TRIGGER trg_lock_week_on_payroll_paid
AFTER INSERT ON public.payroll_detail
REFERENCING NEW TABLE AS newrows
FOR EACH STATEMENT
EXECUTE FUNCTION public.tg_lock_week_on_payroll_paid();
