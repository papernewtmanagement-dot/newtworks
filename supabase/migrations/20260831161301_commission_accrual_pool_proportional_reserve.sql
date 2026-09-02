-- Reserve reformulated 2026-08-31 after backfilling Q3 2026 and finding the
-- first version unusable.
--
-- REJECTED: reserve = 0.25 x (projected quarter commissions still to come).
-- Backfill showed week 1 reserve of $1,152.93 against a week 1 pool of $979.59.
-- The reserve was sized off the quarter's commission risk but charged against a
-- single week's settlement, so weeks 1-2 paid zero and the shape simply flipped
-- from back-starved to front-starved. Do not re-propose this form.
--
-- SHIPPED: reserve = reserve_rate x cumulative pool earned QTD x (1 - week/13).
-- Always a fraction of what has actually been earned, so it can never exceed the
-- pool. Decays to exactly zero at week 13, so held money settles to the team at
-- cycle close with no separate true-up step. Effective holdback glides roughly
-- 28% (week 1) -> 21% (week 4) -> 12% (week 8) -> 2% (week 12) -> 0% (week 13).
--
-- reserve_rate 0.30 is PROVISIONAL and carries the safety margin while the
-- commission projection is unproven. Re-fit from commission_projection_log once
-- 4 quarters have closed; expect it to come down.
--
-- The commission-linked reserve is still emitted as reserve_target_commission_linked
-- for calibration only. It does NOT feed the pool.

ALTER TABLE public.commission_projection_log
  ADD COLUMN IF NOT EXISTS pool_cumulative_qtd numeric,
  ADD COLUMN IF NOT EXISTS reserve_target_commission_linked numeric;

CREATE OR REPLACE FUNCTION public.compute_commission_accrual(
  p_agency_id uuid,
  p_week_end_date date,
  p_qtd_actual_commission numeric DEFAULT NULL,
  p_development_exponent numeric DEFAULT 1.25,
  p_reserve_rate numeric DEFAULT 0.30,
  p_pool_cumulative_qtd numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_cycle_start date; v_cycle_end date; v_week_of_cycle int; v_weeks_in_cycle int := 13;
  v_go_live CONSTANT date := '2026-10-04';
  v_qtd_actual numeric; v_anchor numeric; v_dev_share numeric;
  v_projected numeric; v_charge numeric;
  v_reserve numeric; v_reserve_comm_linked numeric; v_decay numeric;
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
  v_projected := GREATEST(v_qtd_actual + GREATEST(0, 1.0 - v_dev_share) * v_anchor, v_qtd_actual);
  v_charge    := LEAST(v_projected * v_week_of_cycle::numeric / v_weeks_in_cycle::numeric, v_projected);

  v_decay     := GREATEST(0, 1.0 - (v_week_of_cycle::numeric / v_weeks_in_cycle::numeric));
  v_reserve   := CASE WHEN p_pool_cumulative_qtd IS NULL THEN NULL
                      ELSE GREATEST(0, p_reserve_rate * p_pool_cumulative_qtd * v_decay) END;
  v_reserve_comm_linked := GREATEST(0, 0.25 * (v_projected - v_qtd_actual));

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
    'still_to_come', ROUND(GREATEST(0, v_projected - v_qtd_actual), 2),
    'reserve_rate', p_reserve_rate,
    'reserve_decay_factor', ROUND(v_decay, 6),
    'pool_cumulative_qtd', CASE WHEN p_pool_cumulative_qtd IS NULL THEN NULL ELSE ROUND(p_pool_cumulative_qtd, 2) END,
    'reserve_target', CASE WHEN v_reserve IS NULL THEN NULL ELSE ROUND(v_reserve, 2) END,
    'reserve_target_commission_linked', ROUND(v_reserve_comm_linked, 2),
    'reserve_semantic', 'reserve_rate x cumulative pool earned QTD x (1 - week/13). Zero at week 13 = automatic true-up. reserve_target_commission_linked is calibration only and does not feed the pool.',
    'applies_to_pool', (v_cycle_start >= v_go_live),
    'go_live_cycle_start', v_go_live,
    'semantic', 'Even-spread commission charge replaces actual QTD commissions in the pool waterfall; reserve is held back from the distributable pool and decays to zero at week 13.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.write_commission_projection(
  p_agency_id uuid,
  p_week_end_date date,
  p_pool_cumulative_qtd numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v jsonb;
BEGIN
  v := public.compute_commission_accrual(p_agency_id, p_week_end_date, NULL, 1.25, 0.30, p_pool_cumulative_qtd);
  IF v IS NULL THEN RETURN NULL; END IF;

  INSERT INTO public.commission_projection_log (
    agency_id, week_end_date, cycle_start, week_of_cycle,
    qtd_actual_commission, anchor_quarter_estimate, development_share,
    projected_quarter_commission, accrual_charge_qtd, reserve_target,
    pool_cumulative_qtd, reserve_target_commission_linked,
    applies_to_pool, diag, updated_at
  ) VALUES (
    p_agency_id, p_week_end_date, (v->>'cycle_start')::date, (v->>'week_of_cycle')::int,
    (v->>'qtd_actual_commission')::numeric, (v->>'anchor_quarter_estimate')::numeric,
    (v->>'development_share')::numeric, (v->>'projected_quarter_commission')::numeric,
    (v->>'accrual_charge_qtd')::numeric, NULLIF(v->>'reserve_target','')::numeric,
    NULLIF(v->>'pool_cumulative_qtd','')::numeric, (v->>'reserve_target_commission_linked')::numeric,
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
    reserve_target = COALESCE(EXCLUDED.reserve_target, public.commission_projection_log.reserve_target),
    pool_cumulative_qtd = COALESCE(EXCLUDED.pool_cumulative_qtd, public.commission_projection_log.pool_cumulative_qtd),
    reserve_target_commission_linked = EXCLUDED.reserve_target_commission_linked,
    applies_to_pool = EXCLUDED.applies_to_pool,
    diag = EXCLUDED.diag,
    updated_at = NOW();

  RETURN v;
END;
$function$;
