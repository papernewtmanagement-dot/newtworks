-- Commission accrual + holdback reserve for the team bonus pool.
-- Peter directive 2026-08-31. Problem: the pool subtracts ACTUAL quarter-to-date
-- commissions. Commissions arrive back-loaded, so early weeks look rich, pay out
-- big, and the back half of the quarter starves. Q3 2026: 60% of pool dollars
-- went out in the first 3 paying weeks while only 26% of commissions had landed.

CREATE TABLE IF NOT EXISTS public.commission_projection_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  week_end_date date NOT NULL,
  cycle_start date NOT NULL,
  week_of_cycle int NOT NULL,
  qtd_actual_commission numeric NOT NULL DEFAULT 0,
  anchor_quarter_estimate numeric NOT NULL DEFAULT 0,
  development_share numeric NOT NULL DEFAULT 0,
  projected_quarter_commission numeric NOT NULL DEFAULT 0,
  accrual_charge_qtd numeric NOT NULL DEFAULT 0,
  reserve_target numeric NOT NULL DEFAULT 0,
  applies_to_pool boolean NOT NULL DEFAULT false,
  diag jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS commission_projection_log_uniq
  ON public.commission_projection_log (agency_id, week_end_date);

ALTER TABLE public.commission_projection_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS commission_projection_log_read ON public.commission_projection_log;
CREATE POLICY commission_projection_log_read ON public.commission_projection_log
  FOR SELECT TO authenticated USING (public.is_agency_admin());

DROP POLICY IF EXISTS commission_projection_log_write ON public.commission_projection_log;
CREATE POLICY commission_projection_log_write ON public.commission_projection_log
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);


-- ---------------------------------------------------------------------------
-- compute_commission_accrual
--
-- Returns the even-spread commission charge and the holdback reserve for one week.
--
--   projected_quarter = qtd_actual + (1 - development_share) * anchor
--   accrual_charge    = projected_quarter * week_of_cycle / 13
--   reserve           = reserve_rate * (projected_quarter - qtd_actual)
--
-- development_share = (week/13)^p is the share of a quarter's commissions
-- normally landed by week w. p = 1.25 is PROVISIONAL. Q3 2026 (the only quarter
-- with data) fits p near 1.5, but one quarter cannot separate a seasonal shape
-- from a growing team, so 1.25 sits deliberately between straight-line (1.0) and
-- the single observed fit. Re-fit from commission_projection_log after 4 closed
-- quarters; do not treat 1.25 as measured.
--
-- reserve_rate 0.25 is likewise provisional and carries the safety margin while
-- the projection is unproven. Reserve falls to zero at week 13 by construction,
-- so the held money settles to the team at cycle close with no separate true-up.
--
-- Anchor = trailing 13-week average weekly commission x 13. Deliberately not a
-- prior-quarter total: payroll commission history only reaches 2026-05-16, so no
-- clean prior quarter exists yet. Weeks with neither a payroll run nor a CPR
-- report are excluded rather than counted as zero.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_commission_accrual(
  p_agency_id uuid,
  p_week_end_date date,
  p_qtd_actual_commission numeric DEFAULT NULL,
  p_development_exponent numeric DEFAULT 1.25,
  p_reserve_rate numeric DEFAULT 0.25
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_cycle_start date; v_cycle_end date; v_week_of_cycle int; v_weeks_in_cycle int := 13;
  v_go_live CONSTANT date := '2026-10-04';
  v_qtd_actual numeric; v_anchor numeric; v_dev_share numeric;
  v_projected numeric; v_charge numeric; v_reserve numeric;
  v_anchor_weeks int;
BEGIN
  SELECT cycle_start, cycle_end, week_of_cycle
    INTO v_cycle_start, v_cycle_end, v_week_of_cycle
  FROM public.current_cycle_info(p_agency_id, p_week_end_date);
  IF v_cycle_start IS NULL THEN RETURN NULL; END IF;

  IF p_qtd_actual_commission IS NOT NULL THEN
    v_qtd_actual := p_qtd_actual_commission;
  ELSE
    SELECT COALESCE(SUM(wk_comm), 0) INTO v_qtd_actual
    FROM (
      SELECT COALESCE(
        (SELECT SUM((kv.value->>'period')::numeric)
           FROM public.payroll_detail pd
           JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id
           CROSS JOIN LATERAL jsonb_each(COALESCE(pd.raw_earnings->'items', '{}'::jsonb)) kv
          WHERE pd.agency_id = p_agency_id
            AND pr.pay_period_end = s.week_end_date
            AND pr.pay_date <= p_week_end_date
            AND kv.key ILIKE '%Comm%'),
        (SELECT SUM(d.commission)
           FROM public.weekly_cpr_reports r
           JOIN public.weekly_cpr_team_detail d ON d.weekly_cpr_report_id = r.id
          WHERE r.agency_id = p_agency_id AND r.week_ending_date = s.week_end_date),
        0) AS wk_comm
      FROM public.team_comp_pool_schedule s
      WHERE s.agency_id = p_agency_id
        AND s.week_end_date >= v_cycle_start
        AND s.week_end_date <= p_week_end_date
    ) qtd;
  END IF;

  SELECT COALESCE(AVG(wk_comm), 0) * v_weeks_in_cycle, COUNT(*)
    INTO v_anchor, v_anchor_weeks
  FROM (
    SELECT COALESCE(
      (SELECT SUM((kv.value->>'period')::numeric)
         FROM public.payroll_detail pd
         JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id
         CROSS JOIN LATERAL jsonb_each(COALESCE(pd.raw_earnings->'items', '{}'::jsonb)) kv
        WHERE pd.agency_id = p_agency_id
          AND pr.pay_period_end = wk.week_ending
          AND pr.pay_date <= p_week_end_date
          AND kv.key ILIKE '%Comm%'),
      (SELECT SUM(d.commission)
         FROM public.weekly_cpr_reports r
         JOIN public.weekly_cpr_team_detail d ON d.weekly_cpr_report_id = r.id
        WHERE r.agency_id = p_agency_id AND r.week_ending_date = wk.week_ending),
      0) AS wk_comm
    FROM (SELECT (p_week_end_date - (n * 7))::date AS week_ending
            FROM generate_series(0, 12) n) wk
    WHERE EXISTS (SELECT 1 FROM public.payroll_runs pr2
                   WHERE pr2.pay_period_end = wk.week_ending AND pr2.pay_date <= p_week_end_date)
       OR EXISTS (SELECT 1 FROM public.weekly_cpr_reports r2
                   WHERE r2.agency_id = p_agency_id AND r2.week_ending_date = wk.week_ending)
  ) anchor_weeks;

  v_dev_share := POWER(v_week_of_cycle::numeric / v_weeks_in_cycle::numeric, p_development_exponent);
  v_projected := v_qtd_actual + GREATEST(0, 1.0 - v_dev_share) * v_anchor;
  v_projected := GREATEST(v_projected, v_qtd_actual);
  v_charge    := v_projected * v_week_of_cycle::numeric / v_weeks_in_cycle::numeric;
  v_charge    := LEAST(v_charge, v_projected);
  v_reserve   := GREATEST(0, p_reserve_rate * (v_projected - v_qtd_actual));

  RETURN jsonb_build_object(
    'cycle_start', v_cycle_start,
    'cycle_end', v_cycle_end,
    'week_of_cycle', v_week_of_cycle,
    'weeks_in_cycle', v_weeks_in_cycle,
    'qtd_actual_commission', ROUND(v_qtd_actual, 2),
    'anchor_quarter_estimate', ROUND(v_anchor, 2),
    'anchor_weeks_counted', v_anchor_weeks,
    'development_share', ROUND(v_dev_share, 6),
    'development_exponent', p_development_exponent,
    'projected_quarter_commission', ROUND(v_projected, 2),
    'accrual_charge_qtd', ROUND(v_charge, 2),
    'reserve_rate', p_reserve_rate,
    'reserve_target', ROUND(v_reserve, 2),
    'still_to_come', ROUND(GREATEST(0, v_projected - v_qtd_actual), 2),
    'applies_to_pool', (v_cycle_start >= v_go_live),
    'go_live_cycle_start', v_go_live,
    'semantic', 'Even-spread commission charge replaces actual QTD commissions in the pool waterfall; reserve is held back from the distributable pool and decays to zero at week 13.'
  );
END;
$function$;


-- Writer: snapshot one week into commission_projection_log.
CREATE OR REPLACE FUNCTION public.write_commission_projection(
  p_agency_id uuid,
  p_week_end_date date
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v jsonb;
BEGIN
  v := public.compute_commission_accrual(p_agency_id, p_week_end_date);
  IF v IS NULL THEN RETURN NULL; END IF;

  INSERT INTO public.commission_projection_log (
    agency_id, week_end_date, cycle_start, week_of_cycle,
    qtd_actual_commission, anchor_quarter_estimate, development_share,
    projected_quarter_commission, accrual_charge_qtd, reserve_target,
    applies_to_pool, diag, updated_at
  ) VALUES (
    p_agency_id, p_week_end_date, (v->>'cycle_start')::date, (v->>'week_of_cycle')::int,
    (v->>'qtd_actual_commission')::numeric, (v->>'anchor_quarter_estimate')::numeric,
    (v->>'development_share')::numeric, (v->>'projected_quarter_commission')::numeric,
    (v->>'accrual_charge_qtd')::numeric, (v->>'reserve_target')::numeric,
    (v->>'applies_to_pool')::boolean, v, NOW()
  )
  ON CONFLICT (agency_id, week_end_date) DO UPDATE SET
    cycle_start = EXCLUDED.cycle_start,
    week_of_cycle = EXCLUDED.week_of_cycle,
    qtd_actual_commission = EXCLUDED.qtd_actual_commission,
    anchor_quarter_estimate = EXCLUDED.anchor_quarter_estimate,
    development_share = EXCLUDED.development_share,
    projected_quarter_commission = EXCLUDED.projected_quarter_commission,
    accrual_charge_qtd = EXCLUDED.accrual_charge_qtd,
    reserve_target = EXCLUDED.reserve_target,
    applies_to_pool = EXCLUDED.applies_to_pool,
    diag = EXCLUDED.diag,
    updated_at = NOW();

  RETURN v;
END;
$function$;
