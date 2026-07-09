-- Seat assessment: Coverage + Profitability + Lapse Quality wire.
-- Unified attribution model (per core_principles #700 65/35 joint attribution on renewal income).
-- Sales: 100% of own new × 4 + 65% of own renewal stack (Wk52+ gate).
-- Retention: same base + agency_renewal_TTM × 0.35 × person_hours_share.
-- Two bars: Coverage (fully_loaded) + Profitability (fully_loaded × 2.5). Same 100%/80% thresholds.
-- Agency-level lapse rate green/yellow/red vs 12% / 20% benchmark.

CREATE OR REPLACE FUNCTION public.compute_agency_renewal_ttm(
  p_agency_id uuid,
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
  SELECT COALESCE(SUM(amount), 0)::numeric
  FROM public.comp_recap
  WHERE agency_id = p_agency_id
    AND make_date(period_year, period_month, 1) > (p_as_of_date - INTERVAL '12 months')::date
    AND make_date(period_year, period_month, 1) <= p_as_of_date
    AND comp_category IN ('auto_renewal','fire_renewal','life_renewal','health_renewal');
$function$;

COMMENT ON FUNCTION public.compute_agency_renewal_ttm(uuid, date) IS
'Trailing 12 months of agency renewal income across all categories from comp_recap.';

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS fully_loaded_annual numeric,
  ADD COLUMN IF NOT EXISTS attributed_revenue_annual numeric,
  ADD COLUMN IF NOT EXISTS own_new_business_annualized numeric,
  ADD COLUMN IF NOT EXISTS own_renewal_stack_credited numeric,
  ADD COLUMN IF NOT EXISTS retention_pool_share_annual numeric,
  ADD COLUMN IF NOT EXISTS coverage_bar numeric,
  ADD COLUMN IF NOT EXISTS coverage_pct numeric,
  ADD COLUMN IF NOT EXISTS coverage_status text,
  ADD COLUMN IF NOT EXISTS profitability_bar numeric,
  ADD COLUMN IF NOT EXISTS profitability_pct numeric,
  ADD COLUMN IF NOT EXISTS profitability_status text,
  ADD COLUMN IF NOT EXISTS lapse_rate_used numeric,
  ADD COLUMN IF NOT EXISTS lapse_status text;

DROP FUNCTION IF EXISTS public.compute_warning_trigger(uuid, date);

CREATE OR REPLACE FUNCTION public.compute_warning_trigger(p_agency_id uuid, p_week_end_date date)
RETURNS TABLE(
  team_member_id uuid, full_name text, role text, role_category text,
  annual_base numeric, tenure_multiplier numeric, fully_loaded_annual numeric,
  trailing_q_num integer, trailing_q_pc_premium numeric, trailing_q_lh_premium numeric,
  trailing_q_agency_comm_stripped numeric,
  own_new_business_annualized numeric, renewal_stack_annual numeric,
  own_renewal_stack_credited numeric, retention_pool_share_annual numeric,
  attributed_revenue_annual numeric,
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
  v_lapse_green_max     CONSTANT numeric := 0.12;
  v_lapse_yellow_max    CONSTANT numeric := 0.20;
  v_lh_blended_rate     numeric; v_smvc_rate_pc numeric; v_trailing_q int;
  v_month_start int; v_month_end int;
  v_agency_renewal_ttm  numeric; v_blended_lapse numeric; v_lapse_status text;
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
  SELECT annualized_rate INTO v_blended_lapse FROM public.compute_lapse_rate(p_agency_id, p_week_end_date) WHERE line = 'blended';
  IF v_blended_lapse IS NULL THEN v_blended_lapse := 0; END IF;
  v_lapse_status := CASE
    WHEN v_blended_lapse <= v_lapse_green_max THEN 'green'
    WHEN v_blended_lapse <= v_lapse_yellow_max THEN 'yellow'
    ELSE 'red'
  END;

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
      b.c_annual_base * b.c_tenure_mult * (1 + v_burden_multiplier) AS c_fully_loaded,
      COALESCE(tp.pc_prem, 0) AS pc_prem,
      COALESCE(tp.lh_prem, 0) AS lh_prem,
      COALESCE(tp.pc_prem, 0) * v_pc_base_rate + COALESCE(tp.lh_prem, 0) * v_lh_blended_rate AS q_agency_comm_stripped,
      COALESCE(rs.annual_renewal_stack, 0) AS renewal_stack_raw,
      COALESCE(rh.retention_hours_share_frac, 0) AS retention_share_frac
    FROM base_calc b
    LEFT JOIN trailing_prem tp ON tp.team_member_id = b.id
    LEFT JOIN LATERAL public.compute_renewal_stack(b.id, p_week_end_date) rs ON true
    LEFT JOIN retention_hours rh ON rh.team_member_id = b.id
  ),
  computed AS (
    SELECT c.*, c.q_agency_comm_stripped * 4.0 AS own_new_annualized,
      CASE WHEN c.c_tenure_mult >= 1.0 THEN c.renewal_stack_raw * v_stack_producer_pct ELSE 0 END AS own_stack_credited,
      CASE WHEN c.role_category = 'Retention'
           THEN v_agency_renewal_ttm * v_retention_split * c.retention_share_frac
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
      'week_end_date', p_week_end_date, 'burden_multiplier', v_burden_multiplier,
      'pc_base_rate', v_pc_base_rate, 'lh_blended_rate', v_lh_blended_rate,
      'profitability_multiplier', v_profitability_mult, 'retention_split', v_retention_split,
      'stack_producer_share', v_stack_producer_pct,
      'agency_renewal_ttm', ROUND(v_agency_renewal_ttm, 2),
      'blended_lapse_rate', ROUND(v_blended_lapse, 6),
      'lapse_thresholds', jsonb_build_object('green_max', v_lapse_green_max, 'yellow_max', v_lapse_yellow_max),
      'role', f.role, 'role_category', f.role_category,
      'annual_base', ROUND(f.c_annual_base, 2), 'tenure_multiplier', ROUND(f.c_tenure_mult, 4),
      'fully_loaded_annual', ROUND(f.c_fully_loaded, 2),
      'trailing_q_num', v_trailing_q, 'trailing_q_months', jsonb_build_array(v_month_start, v_month_end),
      'trailing_q_pc_prem', ROUND(f.pc_prem, 2), 'trailing_q_lh_prem', ROUND(f.lh_prem, 2),
      'own_new_annualized', ROUND(f.own_new_annualized, 2),
      'renewal_stack_raw', ROUND(f.renewal_stack_raw, 2),
      'own_stack_credited', ROUND(f.own_stack_credited, 2),
      'stack_gate', 'tenure_multiplier >= 1.0 (Week 52+)',
      'retention_hours_share_frac', ROUND(f.retention_share_frac, 6),
      'retention_pool_share_annual', ROUND(f.retention_pool_share, 2),
      'attributed_revenue_annual', ROUND(f.attributed_revenue, 2),
      'coverage_bar', ROUND(f.coverage_bar_val, 2),
      'profitability_bar', ROUND(f.profitability_bar_val, 2),
      'thresholds', jsonb_build_object('green_min_pct', 100, 'yellow_min_pct', 80),
      'formulas', jsonb_build_object(
        'attribution', 'own_new × 4 + (own_stack × 0.65 IF Wk52+) + retention_pool_share',
        'coverage_bar', 'annual_base × tenure_mult × 1.08',
        'profitability_bar', 'coverage_bar × 2.5',
        'retention_pool_share', 'agency_renewal_ttm × 0.35 × (person_wh / total_retention_wh)'
      )
    )
  FROM final f
  ORDER BY f.full_name;
END;
$function$;

COMMENT ON FUNCTION public.compute_warning_trigger(uuid, date) IS
'Per-person weekly seat assessment: Coverage + Profitability + Lapse Quality. '
'Unified attribution: own_new × 4 + own_stack × 0.65 (Wk52+) + retention_pool_share (Retention only). '
'Retention pool = agency_renewal_TTM × 0.35 × person_hours_share. '
'Coverage bar = fully-loaded; Profitability bar = fully-loaded × 2.5. Green ≥100%, Yellow ≥80%. '
'Lapse: green ≤12%, yellow 12-20%, red >20%. Legacy warning_* columns kept for backward compat.';

CREATE OR REPLACE FUNCTION public.write_weekly_comp_v2(p_agency_id uuid, p_week_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_rows_updated int := 0; v_wt_rows int := 0; v_report_id uuid; v_mktg_result jsonb;
BEGIN
  SELECT id INTO v_report_id FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date LIMIT 1;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object('agency_id', p_agency_id, 'week_end_date', p_week_end_date,
      'rows_updated', 0, 'note', 'no weekly_cpr_reports row exists for this week', 'written_at', now());
  END IF;

  WITH src AS (SELECT * FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date)),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET base_salary_paid = s.weekly_base_salary,
        commission_paid  = s.weekly_commission_projected,
        bonus_gross      = ROUND(s.annual_bonus_gross / 52.0, 2),
        health_subtracted= ROUND(s.annual_health_subtracted / 52.0, 2),
        bonus_net        = s.weekly_bonus_net,
        residual_pool_diag = s.diagnostics || jsonb_build_object(
          'annual_base_salary', s.annual_base_salary,
          'annual_commission_projected', s.annual_commission_projected,
          'annual_bonus_gross', s.annual_bonus_gross,
          'annual_health_subtracted', s.annual_health_subtracted,
          'annual_bonus_net', s.annual_bonus_net,
          'annual_total_comp', s.annual_total_comp,
          'ytd_sales_points', s.ytd_sales_points,
          'sales_points_share_pct', s.sales_points_share_pct,
          'weighted_hours_at_40', s.weighted_hours_at_40,
          'retention_hours_share_pct', s.retention_hours_share_pct,
          'person_share_pct', s.person_share_pct),
        updated_at = now()
    FROM src s
    WHERE wctd.weekly_cpr_report_id = v_report_id AND wctd.team_member_id = s.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_rows_updated FROM upd;

  WITH wt AS (SELECT * FROM public.compute_warning_trigger(p_agency_id, p_week_end_date)),
  wt_upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET fully_loaded_annual = w.fully_loaded_annual,
        attributed_revenue_annual = w.attributed_revenue_annual,
        own_new_business_annualized = w.own_new_business_annualized,
        own_renewal_stack_credited = w.own_renewal_stack_credited,
        retention_pool_share_annual = w.retention_pool_share_annual,
        coverage_bar = w.coverage_bar,
        coverage_pct = w.coverage_pct,
        coverage_status = w.coverage_status,
        profitability_bar = w.profitability_bar,
        profitability_pct = w.profitability_pct,
        profitability_status = w.profitability_status,
        lapse_rate_used = w.lapse_rate_used,
        lapse_status = w.lapse_status,
        renewal_stack_annual = w.renewal_stack_annual,
        warning_bar = w.warning_bar,
        warning_actual_annual = w.warning_actual_annual,
        warning_pct = w.warning_pct,
        warning_status = w.warning_status,
        warning_diag = w.diag,
        updated_at = now()
    FROM wt w
    WHERE wctd.weekly_cpr_report_id = v_report_id AND wctd.team_member_id = w.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_wt_rows FROM wt_upd;

  BEGIN
    v_mktg_result := public.write_weekly_marketing_bonus(p_agency_id, p_week_end_date);
  EXCEPTION WHEN OTHERS THEN
    v_mktg_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE);
  END;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
    'weekly_cpr_report_id', v_report_id,
    'rows_updated', v_rows_updated,
    'warning_trigger_rows_updated', v_wt_rows,
    'marketing_bonus_result', v_mktg_result,
    'written_at', now()
  );
END;
$function$;
