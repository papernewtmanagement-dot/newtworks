-- Wire renewal stack into warning_trigger Phase 1.
-- Adds renewal_stack_annual to weekly_cpr_team_detail.
-- Reworks compute_warning_trigger:
--   * LEFT JOIN LATERAL compute_renewal_stack per team member
--   * Renewal stack effective = CASE WHEN tenure_multiplier >= 1.0 THEN stack ELSE 0 (post-Week 52 gate)
--   * warning_actual_annual = (trailing-q new-business commission stripped × 4) + renewal_stack_effective
--   * warning_pct + warning_status recomputed against new actual
--   * diag jsonb gains renewal_stack fields
-- Updates write_weekly_comp_v2 to store renewal_stack_annual.

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS renewal_stack_annual numeric;

DROP FUNCTION IF EXISTS public.compute_warning_trigger(uuid, date);

CREATE OR REPLACE FUNCTION public.compute_warning_trigger(p_agency_id uuid, p_week_end_date date)
RETURNS TABLE(
  team_member_id uuid,
  full_name text,
  role text,
  role_category text,
  role_production_weight numeric,
  annual_base numeric,
  tenure_multiplier numeric,
  warning_bar_full numeric,
  warning_bar numeric,
  trailing_q_num integer,
  trailing_q_pc_premium numeric,
  trailing_q_lh_premium numeric,
  trailing_q_agency_comm_stripped numeric,
  renewal_stack_annual numeric,
  warning_actual_annual numeric,
  warning_pct numeric,
  warning_status text,
  diag jsonb
)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_year                int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_burden_multiplier   CONSTANT numeric := 0.08;
  v_pc_base_rate        CONSTANT numeric := 0.08;
  v_retention_role_wt   CONSTANT numeric := 0.25;
  v_lh_blended_rate     numeric;
  v_smvc_rate_pc        numeric;
  v_trailing_q          int;
  v_month_start         int;
  v_month_end           int;
BEGIN
  SELECT smvc_rate_pc, blended_rate_other
  INTO v_smvc_rate_pc, v_lh_blended_rate
  FROM public.agency
  WHERE id = p_agency_id;

  IF v_lh_blended_rate IS NULL THEN v_lh_blended_rate := 0.09; END IF;

  SELECT MAX(qn) INTO v_trailing_q
  FROM (
    SELECT ((period_month - 1) / 3) + 1 AS qn
    FROM public.producer_production
    WHERE agency_id = p_agency_id AND period_year = v_year
    GROUP BY ((period_month - 1) / 3) + 1
  ) q;

  v_month_start := CASE WHEN v_trailing_q IS NULL THEN NULL ELSE (v_trailing_q - 1) * 3 + 1 END;
  v_month_end   := CASE WHEN v_trailing_q IS NULL THEN NULL ELSE v_trailing_q * 3 END;

  RETURN QUERY
  WITH roster AS (
    SELECT et.team_id AS id, et.first_name, et.last_name,
      et.role, et.role_category, t.pay_type, t.pay_rate, et.start_date,
      CASE WHEN et.role_category = 'Retention' THEN v_retention_role_wt ELSE 1.00 END AS c_role_prod_wt
    FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
    JOIN public.team t ON t.id = et.team_id
  ),
  base_calc AS (
    SELECT r.id, r.first_name || ' ' || r.last_name AS full_name,
      r.role, r.role_category, r.c_role_prod_wt,
      CASE
        WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 52
        WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * 52
        ELSE 0
      END AS c_annual_base,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS c_tenure_mult
    FROM roster r
  ),
  trailing_prem AS (
    SELECT
      pp.team_member_id,
      COALESCE(SUM(CASE WHEN pp.line_of_business IN ('Auto','Fire') THEN pp.premium_issued END), 0) AS pc_prem,
      COALESCE(SUM(CASE WHEN pp.line_of_business IN ('Life','Health') THEN pp.premium_issued END), 0) AS lh_prem
    FROM public.producer_production pp
    WHERE pp.agency_id = p_agency_id
      AND pp.period_year = v_year
      AND v_month_start IS NOT NULL
      AND pp.period_month BETWEEN v_month_start AND v_month_end
    GROUP BY pp.team_member_id
  ),
  with_stack AS (
    SELECT
      b.id, b.full_name, b.role, b.role_category, b.c_role_prod_wt,
      b.c_annual_base, b.c_tenure_mult,
      b.c_annual_base * b.c_tenure_mult * (1 + v_burden_multiplier) AS warning_bar_full,
      b.c_annual_base * b.c_tenure_mult * (1 + v_burden_multiplier) * b.c_role_prod_wt AS warning_bar_adjusted,
      COALESCE(tp.pc_prem, 0) AS pc_prem,
      COALESCE(tp.lh_prem, 0) AS lh_prem,
      COALESCE(tp.pc_prem, 0) * v_pc_base_rate + COALESCE(tp.lh_prem, 0) * v_lh_blended_rate AS q_agency_comm_stripped,
      COALESCE(rs.annual_renewal_stack, 0) AS renewal_stack_raw,
      COALESCE(rs.blended_lapse_annual, 0) AS lapse_used,
      COALESCE(rs.eligible_cohort_count, 0) AS eligible_cohort_count,
      COALESCE(rs.cohort_count, 0) AS total_cohort_count
    FROM base_calc b
    LEFT JOIN trailing_prem tp ON tp.team_member_id = b.id
    LEFT JOIN LATERAL public.compute_renewal_stack(b.id, p_week_end_date) rs ON true
  ),
  final AS (
    SELECT
      f.*,
      CASE WHEN f.c_tenure_mult >= 1.0 THEN f.renewal_stack_raw ELSE 0 END AS renewal_stack_effective,
      (f.q_agency_comm_stripped * 4.0)
        + CASE WHEN f.c_tenure_mult >= 1.0 THEN f.renewal_stack_raw ELSE 0 END AS actual_annual
    FROM with_stack f
  )
  SELECT
    f.id, f.full_name, f.role, f.role_category,
    ROUND(f.c_role_prod_wt, 4),
    ROUND(f.c_annual_base, 2),
    ROUND(f.c_tenure_mult, 4),
    ROUND(f.warning_bar_full, 2),
    ROUND(f.warning_bar_adjusted, 2),
    v_trailing_q,
    ROUND(f.pc_prem, 2),
    ROUND(f.lh_prem, 2),
    ROUND(f.q_agency_comm_stripped, 2),
    ROUND(f.renewal_stack_effective, 2),
    ROUND(f.actual_annual, 2),
    CASE WHEN f.warning_bar_adjusted > 0
         THEN ROUND((f.actual_annual / f.warning_bar_adjusted) * 100, 2)
         ELSE NULL END,
    CASE
      WHEN f.warning_bar_adjusted <= 0 THEN 'na'
      WHEN f.actual_annual >= f.warning_bar_adjusted THEN 'green'
      WHEN f.actual_annual >= f.warning_bar_adjusted * 0.8 THEN 'yellow'
      ELSE 'red'
    END,
    jsonb_build_object(
      'week_end_date', p_week_end_date,
      'burden_multiplier', v_burden_multiplier,
      'pc_base_rate', v_pc_base_rate,
      'lh_blended_rate', v_lh_blended_rate,
      'smvc_rate_pc', v_smvc_rate_pc,
      'role', f.role,
      'role_category', f.role_category,
      'role_production_weight', ROUND(f.c_role_prod_wt, 4),
      'role_adjustment_note', 'Retention roles: bar × 0.25 (75% credit for service/retention contribution). All others: bar × 1.00.',
      'trailing_q_num', v_trailing_q,
      'trailing_q_months', jsonb_build_array(v_month_start, v_month_end),
      'trailing_q_pc_prem', ROUND(f.pc_prem, 2),
      'trailing_q_lh_prem', ROUND(f.lh_prem, 2),
      'trailing_q_new_comm_annualized', ROUND(f.q_agency_comm_stripped * 4.0, 2),
      'renewal_stack_raw', ROUND(f.renewal_stack_raw, 2),
      'renewal_stack_effective', ROUND(f.renewal_stack_effective, 2),
      'renewal_stack_gate', 'tenure_multiplier >= 1.0 (Week 52+)',
      'renewal_stack_eligible_cohorts', f.eligible_cohort_count,
      'renewal_stack_total_cohorts', f.total_cohort_count,
      'renewal_stack_blended_lapse', ROUND(f.lapse_used, 6),
      'annual_base', ROUND(f.c_annual_base, 2),
      'tenure_multiplier', ROUND(f.c_tenure_mult, 4),
      'ramped_base', ROUND(f.c_annual_base * f.c_tenure_mult, 2),
      'warning_bar_full', ROUND(f.warning_bar_full, 2),
      'warning_bar_adjusted', ROUND(f.warning_bar_adjusted, 2),
      'warning_bar_formula', '(annual_base × tenure_mult) × 1.08 × role_production_weight',
      'warning_actual_formula', '(pc_prem × 0.08 + lh_prem × blended_rate) × 4 + renewal_stack_effective',
      'thresholds', jsonb_build_object('green_min_pct', 100, 'yellow_min_pct', 80)
    )
  FROM final f
  ORDER BY f.full_name;
END;
$function$;

CREATE OR REPLACE FUNCTION public.write_weekly_comp_v2(p_agency_id uuid, p_week_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_rows_updated int := 0;
  v_wt_rows int := 0;
  v_report_id    uuid;
  v_mktg_result  jsonb;
BEGIN
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date
  LIMIT 1;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
      'rows_updated', 0,
      'note', 'no weekly_cpr_reports row exists for this week',
      'written_at', now()
    );
  END IF;

  WITH src AS (
    SELECT * FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date)
  ),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET
      base_salary_paid   = s.weekly_base_salary,
      commission_paid    = s.weekly_commission_projected,
      bonus_gross        = ROUND(s.annual_bonus_gross / 52.0, 2),
      health_subtracted  = ROUND(s.annual_health_subtracted / 52.0, 2),
      bonus_net          = s.weekly_bonus_net,
      residual_pool_diag = s.diagnostics
                           || jsonb_build_object(
                                'annual_base_salary',          s.annual_base_salary,
                                'annual_commission_projected', s.annual_commission_projected,
                                'annual_bonus_gross',          s.annual_bonus_gross,
                                'annual_health_subtracted',    s.annual_health_subtracted,
                                'annual_bonus_net',            s.annual_bonus_net,
                                'annual_total_comp',           s.annual_total_comp,
                                'ytd_sales_points',            s.ytd_sales_points,
                                'sales_points_share_pct',      s.sales_points_share_pct,
                                'weighted_hours_at_40',        s.weighted_hours_at_40,
                                'retention_hours_share_pct',   s.retention_hours_share_pct,
                                'person_share_pct',            s.person_share_pct),
      updated_at = now()
    FROM src s
    WHERE wctd.weekly_cpr_report_id = v_report_id
      AND wctd.team_member_id = s.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_rows_updated FROM upd;

  WITH wt AS (
    SELECT * FROM public.compute_warning_trigger(p_agency_id, p_week_end_date)
  ),
  wt_upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET
      warning_bar           = w.warning_bar,
      warning_actual_annual = w.warning_actual_annual,
      warning_pct           = w.warning_pct,
      warning_status        = w.warning_status,
      warning_diag          = w.diag,
      renewal_stack_annual  = w.renewal_stack_annual,
      updated_at            = now()
    FROM wt w
    WHERE wctd.weekly_cpr_report_id = v_report_id
      AND wctd.team_member_id = w.team_member_id
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

COMMENT ON FUNCTION public.compute_warning_trigger(uuid, date) IS
'Per-person weekly warning trigger. Bar = annual_base × tenure_mult × 1.08 × role_production_weight. '
'Actual = trailing-quarter new-business agency commission (SMVC-stripped) × 4 + renewal_stack_effective. '
'Renewal stack applies Week 52+ only (tenure_multiplier >= 1.0). Green ≥100%, Yellow ≥80%, Red <80%.';
