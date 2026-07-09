-- compute_seat_projection: project when a person will hit Coverage/Profitability green.
-- Iterates monthly for max_months (default 60 = 5 years).
-- Assumptions:
--   * new-business pace = current trailing-quarter x 4 (annualized), constant going forward
--   * lapse rate = current blended, constant
--   * retention_pool_share = current, constant (understates future growth as Sales books mature)
--   * salary constant, no promotions
-- Returns first date attributed_revenue crosses coverage_bar (100%) and profitability_bar (250%).

CREATE OR REPLACE FUNCTION public.compute_seat_projection(
  p_agency_id uuid,
  p_team_member_id uuid,
  p_baseline_date date DEFAULT CURRENT_DATE,
  p_max_months int DEFAULT 60
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
    wt.fully_loaded_annual,
    wt.coverage_bar,
    wt.profitability_bar,
    wt.own_new_business_annualized,
    wt.retention_pool_share_annual,
    wt.attributed_revenue_annual,
    wt.lapse_rate_used,
    wt.trailing_q_pc_premium * 4,
    wt.trailing_q_lh_premium * 4,
    wt.role_category
  INTO
    v_fully_loaded, v_coverage_bar, v_profitability_bar,
    v_own_new_annual, v_retention_pool_share, v_current_attributed,
    v_blended_lapse,
    v_pc_prem_annual, v_lh_prem_annual, v_role_category
  FROM public.compute_warning_trigger(p_agency_id, p_baseline_date) wt
  WHERE wt.team_member_id = p_team_member_id;

  IF v_fully_loaded IS NULL THEN
    RETURN;
  END IF;

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

      IF v_coverage_hit IS NULL AND v_attributed >= v_coverage_bar THEN
        v_coverage_hit := m;
      END IF;
      IF v_profit_hit IS NULL AND v_attributed >= v_profitability_bar THEN
        v_profit_hit := m;
      END IF;

      EXIT WHEN v_coverage_hit IS NOT NULL AND v_profit_hit IS NOT NULL;
    END LOOP;
  END IF;

  RETURN QUERY SELECT
    p_team_member_id,
    p_baseline_date,
    ROUND(v_fully_loaded, 2),
    ROUND(v_coverage_bar, 2),
    ROUND(v_profitability_bar, 2),
    ROUND(v_current_attributed, 2),
    CASE WHEN v_coverage_bar > 0
         THEN ROUND((v_current_attributed / v_coverage_bar) * 100, 2)
         ELSE NULL END,
    CASE WHEN v_profitability_bar > 0
         THEN ROUND((v_current_attributed / v_profitability_bar) * 100, 2)
         ELSE NULL END,
    CASE WHEN v_coverage_hit IS NOT NULL
         THEN (p_baseline_date + (v_coverage_hit || ' months')::interval)::date
         ELSE NULL END,
    v_coverage_hit,
    CASE WHEN v_profit_hit IS NOT NULL
         THEN (p_baseline_date + (v_profit_hit || ' months')::interval)::date
         ELSE NULL END,
    v_profit_hit,
    jsonb_build_object(
      'baseline_date', p_baseline_date,
      'max_months_horizon', p_max_months,
      'role_category', v_role_category,
      'assumed_new_business_pace_pc_annual', ROUND(v_pc_prem_annual, 2),
      'assumed_new_business_pace_lh_annual', ROUND(v_lh_prem_annual, 2),
      'assumed_lapse_rate', ROUND(v_blended_lapse, 6),
      'survival_rate_L', ROUND(v_L, 6),
      'assumed_retention_pool_share_annual', ROUND(v_retention_pool_share, 2),
      'stack_producer_share', v_stack_producer_pct,
      'notes', jsonb_build_array(
        'Projection holds new-business pace and lapse constant',
        'Retention pool held constant (understates future growth as Sales books mature)',
        'No salary or promotion changes modeled',
        'Retention roles with static attribution will show NULL if they never reach green under current lapse'
      )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.compute_seat_projections_for_agency(
  p_agency_id uuid,
  p_baseline_date date DEFAULT CURRENT_DATE,
  p_max_months int DEFAULT 60
)
RETURNS TABLE (
  team_member_id uuid,
  full_name text,
  role text,
  role_category text,
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
BEGIN
  RETURN QUERY
  SELECT
    wt.team_member_id,
    wt.full_name,
    wt.role,
    wt.role_category,
    sp.baseline_date,
    sp.fully_loaded_annual,
    sp.coverage_bar,
    sp.profitability_bar,
    sp.current_attributed_annual,
    sp.current_coverage_pct,
    sp.current_profitability_pct,
    sp.coverage_green_est_date,
    sp.coverage_green_est_months,
    sp.profitability_green_est_date,
    sp.profitability_green_est_months,
    sp.assumptions
  FROM public.compute_warning_trigger(p_agency_id, p_baseline_date) wt
  CROSS JOIN LATERAL public.compute_seat_projection(p_agency_id, wt.team_member_id, p_baseline_date, p_max_months) sp
  ORDER BY wt.full_name;
END;
$function$;

COMMENT ON FUNCTION public.compute_seat_projection(uuid, uuid, date, int) IS
'Project when a seat will hit Coverage green (100%) and Profitability green (250%). '
'Iterates monthly up to max_months. Assumes new-business pace + lapse + retention pool held constant. '
'Returns NULL for a threshold if not crossed within horizon.';
