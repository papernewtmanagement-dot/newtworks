DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.compute_warning_trigger(uuid,date,numeric,jsonb)'::regprocedure)) <> 'f5fa7ffb89f743dfc5f19ca77e5d5d72' THEN
    RAISE EXCEPTION 'compute_warning_trigger changed since read; re-fetch before migrating';
  END IF;
END $g$;
CREATE OR REPLACE FUNCTION public.compute_warning_trigger(p_agency_id uuid, p_week_end_date date, p_override_lapse numeric DEFAULT NULL::numeric, p_retention_hours jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(team_member_id uuid, full_name text, role text, role_category text, annual_base numeric, tenure_multiplier numeric, fully_loaded_annual numeric, trailing_q_num integer, trailing_q_pc_premium numeric, trailing_q_lh_premium numeric, trailing_q_agency_comm_stripped numeric, own_new_business_annualized numeric, renewal_stack_annual numeric, own_renewal_stack_credited numeric, retention_pool_share_annual numeric, retention_quality_multiplier numeric, attributed_revenue_annual numeric, coverage_bar numeric, coverage_pct numeric, coverage_status text, profitability_bar numeric, profitability_pct numeric, profitability_status text, lapse_rate_used numeric, lapse_status text, warning_bar_full numeric, warning_bar numeric, warning_actual_annual numeric, warning_pct numeric, warning_status text, diag jsonb)
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
  -- Renewal tail = customer lifetime value of a year of new P&C business:
  -- commission x r / (1 + i - r), r = 1 - lapse (capped 0.95), i = 12% (Gupta, Lehmann & Stuart 2004).
  v_discount_rate       CONSTANT numeric := 0.12;
  v_survival_cap        CONSTANT numeric := 0.95;
  v_tail_multiple       numeric;
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
  v_tail_multiple := LEAST(v_survival_cap, GREATEST(0, 1 - v_blended_lapse))
                     / (1 + v_discount_rate - LEAST(v_survival_cap, GREATEST(0, 1 - v_blended_lapse)));

  RETURN QUERY
  WITH roster AS (
    SELECT et.team_id AS id, et.first_name, et.last_name, et.role, et.role_category,
      t.pay_type, t.pay_rate, et.start_date
    FROM public.get_expected_teammates(p_agency_id, 'compensation', p_week_end_date - 6) et
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
    FROM (
      -- write_weekly_comp_v2 passes the weighted hours from the pool run it just made, so the
      -- pool is not run a second time; any other caller leaves it NULL and the pool runs here.
      SELECT x.team_member_id, x.weighted_hours_at_40, x.role_category
      FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date) x
      WHERE p_retention_hours IS NULL
      UNION ALL
      SELECT (e->>'team_member_id')::uuid, (e->>'weighted_hours_at_40')::numeric, e->>'role_category'
      FROM jsonb_array_elements(COALESCE(p_retention_hours, '[]'::jsonb)) e
    ) rpp
    WHERE rpp.role_category = 'Retention'
  ),
  compose AS (
    SELECT b.id, b.full_name, b.role, b.role_category, b.c_annual_base, b.c_tenure_mult,
      CASE WHEN ot.on_time_annual IS NOT NULL
           THEN (ot.on_time_annual - COALESCE(ot.annual_benefits, 0)) * (1 + v_burden_multiplier) + COALESCE(ot.annual_benefits, 0)
           ELSE b.c_annual_base * (1 + v_burden_multiplier) END AS c_fully_loaded,
      (ot.on_time_annual IS NOT NULL) AS c_pay_from_actual,
      COALESCE(tp.pc_prem, 0) AS pc_prem,
      COALESCE(tp.lh_prem, 0) AS lh_prem,
      COALESCE(tp.pc_prem, 0) * v_pc_base_rate + COALESCE(tp.lh_prem, 0) * v_lh_blended_rate AS q_agency_comm_stripped,
      COALESCE(rs.annual_renewal_stack, 0) AS renewal_stack_raw,
      COALESCE(rh.retention_hours_share_frac, 0) AS retention_share_frac
    FROM base_calc b
    LEFT JOIN trailing_prem tp ON tp.team_member_id = b.id
    LEFT JOIN LATERAL public.compute_renewal_stack(b.id, p_week_end_date, v_blended_lapse) rs ON true
    LEFT JOIN retention_hours rh ON rh.team_member_id = b.id
    LEFT JOIN public.team_on_time_annual_pay(p_agency_id, p_week_end_date) ot ON ot.team_member_id = b.id
  ),
  computed AS (
    SELECT c.*, c.q_agency_comm_stripped * 4.0 AS own_new_annualized,
      c.pc_prem * 4.0 * v_pc_base_rate * v_tail_multiple * v_stack_producer_pct AS own_stack_credited,
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
      'renewal_basis', 'lifetime value of trailing-quarter P&C new commission x 4; renewal_stack_raw is the current-year stack, informational only',
      'discount_rate', v_discount_rate,
      'renewal_tail_multiple', ROUND(v_tail_multiple, 4),
      'cost_basis', CASE WHEN f.c_pay_from_actual THEN 'team_on_time_annual_pay x burden (benefits unburdened)' ELSE 'annual base x burden (no pay history yet)' END,
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

