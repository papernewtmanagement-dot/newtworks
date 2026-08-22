-- Add optional p_override_lapse to compute_renewal_stack, compute_warning_trigger,
-- compute_seat_projection, compute_seat_projections_for_agency.
-- When NULL (default), behavior unchanged. When provided, that value is used everywhere
-- lapse enters the math: RQM, decay in existing cohorts, decay in future cohorts.
-- Enables "what if lapse were X%?" scenarios without touching actuals.

-- 1) compute_renewal_stack: accept override
CREATE OR REPLACE FUNCTION public.compute_renewal_stack(
  p_team_member_id uuid,
  p_as_of_date date DEFAULT CURRENT_DATE,
  p_override_lapse numeric DEFAULT NULL
)
RETURNS TABLE(annual_renewal_stack numeric, cohort_count integer, diag jsonb)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_agency_id           uuid;
  v_pc_rate             CONSTANT numeric := 0.08;
  v_lh_rate             numeric;
  v_blended_lapse       numeric;
BEGIN
  SELECT agency_id INTO v_agency_id FROM public.team WHERE id = p_team_member_id;
  IF v_agency_id IS NULL THEN
    RETURN QUERY SELECT 0::numeric, 0, jsonb_build_object('error','team_member not found');
    RETURN;
  END IF;

  SELECT COALESCE(blended_rate_other, 0.09) INTO v_lh_rate
  FROM public.agency WHERE id = v_agency_id;

  IF p_override_lapse IS NOT NULL THEN
    v_blended_lapse := p_override_lapse;
  ELSE
    SELECT annualized_rate INTO v_blended_lapse
    FROM public.compute_lapse_rate(v_agency_id, p_as_of_date)
    WHERE line = 'blended';
    IF v_blended_lapse IS NULL THEN v_blended_lapse := 0; END IF;
  END IF;

  RETURN QUERY
  WITH cohorts AS (
    SELECT
      pp.line_of_business,
      pp.premium_issued,
      make_date(pp.period_year, pp.period_month, 15) AS cohort_date,
      ((p_as_of_date - make_date(pp.period_year, pp.period_month, 15))::numeric / 365.25) AS age_years
    FROM public.producer_production pp
    WHERE pp.team_member_id = p_team_member_id
      AND pp.premium_issued > 0
      AND COALESCE(pp.premium_type, 'new_business') = 'new_business'
      AND make_date(pp.period_year, pp.period_month, 15) < p_as_of_date
  ),
  eligible AS (
    SELECT * FROM cohorts WHERE age_years >= 1.0
  ),
  computed AS (
    SELECT
      SUM(
        premium_issued *
        CASE WHEN line_of_business IN ('Auto','Fire') THEN v_pc_rate ELSE v_lh_rate END *
        POWER(GREATEST(0.01, 1 - v_blended_lapse), age_years)
      ) AS annual_stack,
      COUNT(*)::int AS n_cohorts
    FROM eligible
  )
  SELECT
    COALESCE(c.annual_stack, 0),
    COALESCE(c.n_cohorts, 0),
    jsonb_build_object(
      'as_of_date', p_as_of_date,
      'lapse_used', ROUND(v_blended_lapse, 6),
      'lapse_source', CASE WHEN p_override_lapse IS NOT NULL THEN 'override' ELSE 'compute_lapse_rate' END,
      'pc_rate', v_pc_rate,
      'lh_rate', v_lh_rate,
      'cohorts_eligible', c.n_cohorts
    )
  FROM computed c;
END;
$function$;

-- 2) compute_warning_trigger: accept override
DROP FUNCTION IF EXISTS public.compute_warning_trigger(uuid, date);
DROP FUNCTION IF EXISTS public.compute_warning_trigger(uuid, date, numeric);

CREATE OR REPLACE FUNCTION public.compute_warning_trigger(
  p_agency_id uuid,
  p_week_end_date date,
  p_override_lapse numeric DEFAULT NULL
)
RETURNS TABLE(
  team_member_id uuid, full_name text, role text, role_category text,
  annual_base numeric, tenure_multiplier numeric, fully_loaded_annual numeric,
  trailing_q_num integer, trailing_q_pc_premium numeric, trailing_q_lh_premium numeric,
  trailing_q_agency_comm_stripped numeric,
  own_new_business_annualized numeric, renewal_stack_annual numeric,
  own_renewal_stack_credited numeric, retention_pool_share_annual numeric,
  retention_quality_multiplier numeric, attributed_revenue_annual numeric,
  coverage_bar numeric, coverage_pct numeric, coverage_status text,
  profitability_bar numeric, profitability_pct numeric, profitability_status text,
  lapse_rate_used numeric, lapse_status text,
  warning_bar_full numeric, warning_bar numeric, warning_actual_annual numeric,
  warning_pct numeric, warning_status text, diag jsonb
)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_year                int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_burden_multiplier   CONSTANT numeric := 0.08;
  v_pc_base_rate        CONSTANT numeric := 0.08;
  v_profitability_mult  CONSTANT numeric := 2.5;
  v_retention_split     CONSTANT numeric := 0.35;
  v_stack_producer_pct  CONSTANT numeric := 0.65;
  v_lapse_benchmark     CONSTANT numeric := 0.12;
  v_lapse_green_max     CONSTANT numeric := 0.12;
  v_lapse_yellow_max    CONSTANT numeric := 0.20;
  v_lh_blended_rate     numeric;
  v_smvc_rate_pc        numeric;
  v_trailing_q          int;
  v_month_start         int;
  v_month_end           int;
  v_agency_renewal_ttm  numeric;
  v_blended_lapse       numeric;
  v_lapse_status        text;
  v_retention_quality   numeric;
  v_lapse_source        text;
BEGIN
  SELECT smvc_rate_pc, blended_rate_other INTO v_smvc_rate_pc, v_lh_blended_rate
  FROM public.agency WHERE id = p_agency_id;
  IF v_lh_blended_rate IS NULL THEN v_lh_blended_rate := 0.09; END IF;

  SELECT MAX(qn) INTO v_trailing_q FROM (
    SELECT ((period_month - 1) / 3) + 1 AS qn FROM public.producer_production
    WHERE agency_id = p_agency_id AND period_year = v_year
    GROUP BY ((period_month - 1) / 3) + 1
  ) q;
  v_month_start := CASE WHEN v_trailing_q IS NULL THEN NULL ELSE (v_trailing_q - 1) * 3 + 1 END;
  v_month_end   := CASE WHEN v_trailing_q IS NULL THEN NULL ELSE v_trailing_q * 3 END;

  v_agency_renewal_ttm := public.compute_agency_renewal_ttm(p_agency_id, p_week_end_date);

  IF p_override_lapse IS NOT NULL THEN
    v_blended_lapse := p_override_lapse;
    v_lapse_source := 'override';
  ELSE
    SELECT annualized_rate INTO v_blended_lapse FROM public.compute_lapse_rate(p_agency_id, p_week_end_date) WHERE line = 'blended';
    IF v_blended_lapse IS NULL THEN v_blended_lapse := 0; END IF;
    v_lapse_source := 'compute_lapse_rate';
  END IF;

  v_lapse_status := CASE
    WHEN v_blended_lapse <= v_lapse_green_max THEN 'green'
    WHEN v_blended_lapse <= v_lapse_yellow_max THEN 'yellow'
    ELSE 'red' END;
  v_retention_quality := LEAST(1.0, v_lapse_benchmark / GREATEST(v_blended_lapse, 0.001));

  RETURN QUERY
  WITH roster AS (
    SELECT et.team_id AS id, et.first_name, et.last_name, et.role, et.role_category,
      t.pay_type, t.pay_rate, et.start_date
    FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
    JOIN public.team t ON t.id = et.team_id
  ),
  base_calc AS (
    SELECT r.id, r.first_name || ' ' || r.last_name AS full_name, r.role, r.role_category,
      CASE WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 52
           WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * 52
           ELSE 0 END AS c_annual_base,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS c_tenure_mult
    FROM roster r
  ),
  trailing_prem AS (
    SELECT pp.team_member_id,
      COALESCE(SUM(CASE WHEN pp.line_of_business IN ('Auto','Fire') THEN pp.premium_issued END), 0) AS pc_prem,
      COALESCE(SUM(CASE WHEN pp.line_of_business IN ('Life','Health') THEN pp.premium_issued END), 0) AS lh_prem
    FROM public.producer_production pp
    WHERE pp.agency_id = p_agency_id AND pp.period_year = v_year
      AND v_month_start IS NOT NULL AND pp.period_month BETWEEN v_month_start AND v_month_end
    GROUP BY pp.team_member_id
  ),
  retention_hours AS (
    SELECT rpp.team_member_id, rpp.weighted_hours_at_40,
      rpp.weighted_hours_at_40 / NULLIF(SUM(rpp.weighted_hours_at_40) OVER (), 0) AS retention_hours_share_frac
    FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date) rpp
    WHERE rpp.role_category = 'Retention'
  ),
  compose AS (
    SELECT b.id, b.full_name, b.role, b.role_category, b.c_annual_base, b.c_tenure_mult,
      b.c_annual_base * (1 + v_burden_multiplier) AS c_fully_loaded,
      COALESCE(tp.pc_prem, 0) AS pc_prem,
      COALESCE(tp.lh_prem, 0) AS lh_prem,
      COALESCE(tp.pc_prem, 0) * v_pc_base_rate + COALESCE(tp.lh_prem, 0) * v_lh_blended_rate AS q_agency_comm_stripped,
      COALESCE(rs.annual_renewal_stack, 0) AS renewal_stack_raw,
      COALESCE(rh.retention_hours_share_frac, 0) AS retention_share_frac
    FROM base_calc b
    LEFT JOIN trailing_prem tp ON tp.team_member_id = b.id
    LEFT JOIN LATERAL public.compute_renewal_stack(b.id, p_week_end_date, v_blended_lapse) rs ON true
    LEFT JOIN retention_hours rh ON rh.team_member_id = b.id
  ),
  computed AS (
    SELECT c.*, c.q_agency_comm_stripped * 4.0 AS own_new_annualized,
      c.renewal_stack_raw * v_stack_producer_pct AS own_stack_credited,
      CASE WHEN c.role_category = 'Retention'
           THEN v_agency_renewal_ttm * v_retention_split * c.retention_share_frac * v_retention_quality
           ELSE 0 END AS retention_pool_share
    FROM compose c
  ),
  final AS (
    SELECT f.*, (f.own_new_annualized + f.own_stack_credited + f.retention_pool_share) AS attributed_revenue,
      f.c_fully_loaded AS coverage_bar_val,
      f.c_fully_loaded * v_profitability_mult AS profitability_bar_val
    FROM computed f
  )
  SELECT
    f.id, f.full_name, f.role, f.role_category,
    ROUND(f.c_annual_base, 2), ROUND(f.c_tenure_mult, 4), ROUND(f.c_fully_loaded, 2),
    v_trailing_q, ROUND(f.pc_prem, 2), ROUND(f.lh_prem, 2), ROUND(f.q_agency_comm_stripped, 2),
    ROUND(f.own_new_annualized, 2), ROUND(f.renewal_stack_raw, 2),
    ROUND(f.own_stack_credited, 2), ROUND(f.retention_pool_share, 2),
    ROUND(v_retention_quality, 4),
    ROUND(f.attributed_revenue, 2),
    ROUND(f.coverage_bar_val, 2),
    CASE WHEN f.coverage_bar_val > 0 THEN ROUND((f.attributed_revenue / f.coverage_bar_val) * 100, 2) ELSE NULL END,
    CASE WHEN f.coverage_bar_val <= 0 THEN 'na'
         WHEN f.attributed_revenue >= f.coverage_bar_val THEN 'green'
         WHEN f.attributed_revenue >= f.coverage_bar_val * 0.8 THEN 'yellow'
         ELSE 'red' END,
    ROUND(f.profitability_bar_val, 2),
    CASE WHEN f.profitability_bar_val > 0 THEN ROUND((f.attributed_revenue / f.profitability_bar_val) * 100, 2) ELSE NULL END,
    CASE WHEN f.profitability_bar_val <= 0 THEN 'na'
         WHEN f.attributed_revenue >= f.profitability_bar_val THEN 'green'
         WHEN f.attributed_revenue >= f.profitability_bar_val * 0.8 THEN 'yellow'
         ELSE 'red' END,
    ROUND(v_blended_lapse, 6), v_lapse_status,
    ROUND(f.c_fully_loaded, 2), ROUND(f.coverage_bar_val, 2), ROUND(f.attributed_revenue, 2),
    CASE WHEN f.coverage_bar_val > 0 THEN ROUND((f.attributed_revenue / f.coverage_bar_val) * 100, 2) ELSE NULL END,
    CASE WHEN f.coverage_bar_val <= 0 THEN 'na'
         WHEN f.attributed_revenue >= f.coverage_bar_val THEN 'green'
         WHEN f.attributed_revenue >= f.coverage_bar_val * 0.8 THEN 'yellow'
         ELSE 'red' END,
    jsonb_build_object(
      'week_end_date', p_week_end_date,
      'lapse_source', v_lapse_source,
      'burden_multiplier', v_burden_multiplier,
      'pc_base_rate', v_pc_base_rate,
      'lh_blended_rate', v_lh_blended_rate,
      'profitability_multiplier', v_profitability_mult,
      'retention_split', v_retention_split,
      'stack_producer_share', v_stack_producer_pct,
      'lapse_benchmark', v_lapse_benchmark,
      'agency_renewal_ttm', ROUND(v_agency_renewal_ttm, 2),
      'blended_lapse_rate', ROUND(v_blended_lapse, 6),
      'retention_quality_multiplier', ROUND(v_retention_quality, 4),
      'lapse_thresholds', jsonb_build_object('green_max', v_lapse_green_max, 'yellow_max', v_lapse_yellow_max),
      'role', f.role, 'role_category', f.role_category,
      'annual_base', ROUND(f.c_annual_base, 2),
      'tenure_multiplier', ROUND(f.c_tenure_mult, 4),
      'fully_loaded_annual', ROUND(f.c_fully_loaded, 2),
      'trailing_q_num', v_trailing_q,
      'trailing_q_months', jsonb_build_array(v_month_start, v_month_end),
      'trailing_q_pc_prem', ROUND(f.pc_prem, 2),
      'trailing_q_lh_prem', ROUND(f.lh_prem, 2),
      'own_new_annualized', ROUND(f.own_new_annualized, 2),
      'renewal_stack_raw', ROUND(f.renewal_stack_raw, 2),
      'own_stack_credited', ROUND(f.own_stack_credited, 2),
      'retention_hours_share_frac', ROUND(f.retention_share_frac, 6),
      'retention_pool_share_annual', ROUND(f.retention_pool_share, 2),
      'attributed_revenue_annual', ROUND(f.attributed_revenue, 2),
      'coverage_bar', ROUND(f.coverage_bar_val, 2),
      'profitability_bar', ROUND(f.profitability_bar_val, 2)
    )
  FROM final f
  ORDER BY f.full_name;
END;
$function$;

-- 3) compute_seat_projection: accept override
DROP FUNCTION IF EXISTS public.compute_seat_projection(uuid, uuid, date, int);
DROP FUNCTION IF EXISTS public.compute_seat_projection(uuid, uuid, date, int, numeric);

CREATE OR REPLACE FUNCTION public.compute_seat_projection(
  p_agency_id uuid,
  p_team_member_id uuid,
  p_baseline_date date DEFAULT CURRENT_DATE,
  p_max_months int DEFAULT 60,
  p_override_lapse numeric DEFAULT NULL
)
RETURNS TABLE (
  team_member_id uuid,
  baseline_date date,
  fully_loaded_annual numeric,
  coverage_bar numeric,
  profitability_bar numeric,
  current_attributed_annual numeric,
  current_coverage_pct numeric,
  current_profitability_pct numeric,
  coverage_green_est_date date,
  coverage_green_est_months integer,
  profitability_green_est_date date,
  profitability_green_est_months integer,
  assumptions jsonb
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_fully_loaded         numeric;
  v_coverage_bar         numeric;
  v_profitability_bar    numeric;
  v_own_new_annual       numeric;
  v_retention_pool_share numeric;
  v_current_attributed   numeric;
  v_blended_lapse        numeric;
  v_pc_prem_annual       numeric;
  v_lh_prem_annual       numeric;
  v_role_category        text;
  v_lh_rate              numeric;
  v_pc_rate              CONSTANT numeric := 0.08;
  v_stack_producer_pct   CONSTANT numeric := 0.65;
  v_L                    numeric;
  v_ln_L                 numeric;
  m                      int;
  v_future_date          date;
  v_years_out            numeric;
  v_existing_stack       numeric;
  v_future_stack_factor  numeric;
  v_future_stack         numeric;
  v_attributed           numeric;
  v_coverage_hit         int;
  v_profit_hit           int;
BEGIN
  SELECT
    wt.fully_loaded_annual, wt.coverage_bar, wt.profitability_bar,
    wt.own_new_business_annualized, wt.retention_pool_share_annual,
    wt.attributed_revenue_annual, wt.lapse_rate_used,
    wt.trailing_q_pc_premium * 4, wt.trailing_q_lh_premium * 4,
    wt.role_category
  INTO
    v_fully_loaded, v_coverage_bar, v_profitability_bar,
    v_own_new_annual, v_retention_pool_share, v_current_attributed,
    v_blended_lapse,
    v_pc_prem_annual, v_lh_prem_annual, v_role_category
  FROM public.compute_warning_trigger(p_agency_id, p_baseline_date, p_override_lapse) wt
  WHERE wt.team_member_id = p_team_member_id;

  IF v_fully_loaded IS NULL THEN RETURN; END IF;

  SELECT COALESCE(blended_rate_other, 0.09) INTO v_lh_rate
  FROM public.agency WHERE id = p_agency_id;

  v_L := GREATEST(0.01, 1 - v_blended_lapse);
  v_ln_L := LN(v_L);

  IF v_current_attributed >= v_coverage_bar THEN v_coverage_hit := 0; END IF;
  IF v_current_attributed >= v_profitability_bar THEN v_profit_hit := 0; END IF;

  IF v_coverage_hit IS NULL OR v_profit_hit IS NULL THEN
    FOR m IN 1..p_max_months LOOP
      v_future_date := (p_baseline_date + (m || ' months')::interval)::date;
      v_years_out := m::numeric / 12.0;

      SELECT COALESCE(SUM(
        pp.premium_issued *
        CASE WHEN pp.line_of_business IN ('Auto','Fire') THEN v_pc_rate ELSE v_lh_rate END *
        POWER(v_L, ((v_future_date - make_date(pp.period_year, pp.period_month, 15))::numeric / 365.25))
      ), 0)
      INTO v_existing_stack
      FROM public.producer_production pp
      WHERE pp.team_member_id = p_team_member_id
        AND pp.premium_issued > 0
        AND COALESCE(pp.premium_type, 'new_business') = 'new_business'
        AND make_date(pp.period_year, pp.period_month, 15) < v_future_date
        AND ((v_future_date - make_date(pp.period_year, pp.period_month, 15))::numeric / 365.25) >= 1.0;

      IF v_years_out >= 1.0 THEN
        v_future_stack_factor := (POWER(v_L, v_years_out) - v_L) / v_ln_L;
        v_future_stack := v_pc_prem_annual * v_pc_rate * v_future_stack_factor
                        + v_lh_prem_annual * v_lh_rate * v_future_stack_factor;
      ELSE
        v_future_stack := 0;
      END IF;

      v_attributed := v_own_new_annual
                    + (v_existing_stack + v_future_stack) * v_stack_producer_pct
                    + v_retention_pool_share;

      IF v_coverage_hit IS NULL AND v_attributed >= v_coverage_bar THEN v_coverage_hit := m; END IF;
      IF v_profit_hit IS NULL AND v_attributed >= v_profitability_bar THEN v_profit_hit := m; END IF;
      EXIT WHEN v_coverage_hit IS NOT NULL AND v_profit_hit IS NOT NULL;
    END LOOP;
  END IF;

  RETURN QUERY SELECT
    p_team_member_id, p_baseline_date,
    ROUND(v_fully_loaded, 2), ROUND(v_coverage_bar, 2), ROUND(v_profitability_bar, 2),
    ROUND(v_current_attributed, 2),
    CASE WHEN v_coverage_bar > 0 THEN ROUND((v_current_attributed / v_coverage_bar) * 100, 2) ELSE NULL END,
    CASE WHEN v_profitability_bar > 0 THEN ROUND((v_current_attributed / v_profitability_bar) * 100, 2) ELSE NULL END,
    CASE WHEN v_coverage_hit IS NOT NULL THEN (p_baseline_date + (v_coverage_hit || ' months')::interval)::date ELSE NULL END,
    v_coverage_hit,
    CASE WHEN v_profit_hit IS NOT NULL THEN (p_baseline_date + (v_profit_hit || ' months')::interval)::date ELSE NULL END,
    v_profit_hit,
    jsonb_build_object(
      'baseline_date', p_baseline_date,
      'max_months_horizon', p_max_months,
      'role_category', v_role_category,
      'lapse_source', CASE WHEN p_override_lapse IS NOT NULL THEN 'override' ELSE 'actual' END,
      'assumed_lapse_rate', ROUND(v_blended_lapse, 6),
      'survival_rate_L', ROUND(v_L, 6),
      'assumed_new_business_pace_pc_annual', ROUND(v_pc_prem_annual, 2),
      'assumed_new_business_pace_lh_annual', ROUND(v_lh_prem_annual, 2),
      'assumed_retention_pool_share_annual', ROUND(v_retention_pool_share, 2)
    );
END;
$function$;

-- 4) compute_seat_projections_for_agency: accept override
DROP FUNCTION IF EXISTS public.compute_seat_projections_for_agency(uuid, date, int);
DROP FUNCTION IF EXISTS public.compute_seat_projections_for_agency(uuid, date, int, numeric);

CREATE OR REPLACE FUNCTION public.compute_seat_projections_for_agency(
  p_agency_id uuid,
  p_baseline_date date DEFAULT CURRENT_DATE,
  p_max_months int DEFAULT 60,
  p_override_lapse numeric DEFAULT NULL
)
RETURNS TABLE (
  team_member_id uuid, full_name text, role text, role_category text,
  baseline_date date,
  fully_loaded_annual numeric, coverage_bar numeric, profitability_bar numeric,
  current_attributed_annual numeric, current_coverage_pct numeric, current_profitability_pct numeric,
  coverage_green_est_date date, coverage_green_est_months integer,
  profitability_green_est_date date, profitability_green_est_months integer,
  assumptions jsonb
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    wt.team_member_id, wt.full_name, wt.role, wt.role_category,
    sp.baseline_date,
    sp.fully_loaded_annual, sp.coverage_bar, sp.profitability_bar,
    sp.current_attributed_annual, sp.current_coverage_pct, sp.current_profitability_pct,
    sp.coverage_green_est_date, sp.coverage_green_est_months,
    sp.profitability_green_est_date, sp.profitability_green_est_months,
    sp.assumptions
  FROM public.compute_warning_trigger(p_agency_id, p_baseline_date, p_override_lapse) wt
  CROSS JOIN LATERAL public.compute_seat_projection(p_agency_id, wt.team_member_id, p_baseline_date, p_max_months, p_override_lapse) sp
  ORDER BY wt.full_name;
END;
$function$;
