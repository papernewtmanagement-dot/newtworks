-- 1) Drop the per-person health subtraction column. Never used in production payroll — health was
--    always paid outside of the residual-pool math. Column existed only in the compute/write chain.
ALTER TABLE public.weekly_cpr_team_detail DROP COLUMN IF EXISTS health_subtracted;

-- 2) Drop + recreate compute function with:
--    - annual_health_subtracted removed from return signature
--    - location_w for remote lowered 0.75 -> 0.50
DROP FUNCTION IF EXISTS public.compute_weekly_comp_residual_pool(uuid, date);

CREATE FUNCTION public.compute_weekly_comp_residual_pool(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(team_member_id uuid, full_name text, role text, role_category text, role_level text, annual_base_salary numeric, weekly_base_salary numeric, annual_commission_projected numeric, weekly_commission_projected numeric, ytd_sales_points numeric, sales_points_share_pct numeric, weighted_hours_at_40 numeric, retention_hours_share_pct numeric, person_share_pct numeric, annual_bonus_gross numeric, annual_bonus_net numeric, weekly_bonus_net numeric, annual_total_comp numeric, weekly_total_comp numeric, diagnostics jsonb)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_year               int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_pool_result        jsonb;
  v_carveouts_result   jsonb;
  v_annual_envelope    numeric;
  v_annual_carveouts   numeric;
  v_burden_multiplier  CONSTANT numeric := 0.08;
  v_wc_annual          CONSTANT numeric := 500.00;
BEGIN
  v_pool_result      := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_carveouts_result := public.compute_pool_carveouts(p_agency_id, p_week_end_date);
  v_annual_envelope  := COALESCE(NULLIF(v_pool_result->'envelope'->>'annual_dollars','')::numeric, 0);
  v_annual_carveouts := COALESCE(NULLIF(v_carveouts_result->>'total_annual_carveouts','')::numeric, 0);

  RETURN QUERY
  WITH roster AS (
    SELECT et.team_id AS id, et.first_name, et.last_name, et.role, et.role_category, et.role_level,
           t.pay_type, t.pay_rate, t.work_location, et.start_date,
           t.license_pc, t.license_lh, t.license_ips,
           t.weekly_health_benefit_agency_paid
    FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
    JOIN public.team t ON t.id = et.team_id
  ),
  base_calc AS (
    SELECT r.*,
      CASE
        WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 52
        WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * 52
        ELSE 0
      END AS c_annual_base,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS c_base_tenure_mult
    FROM roster r
  ),
  q_commissions AS (
    SELECT b.id AS tm_id, q,
      (public.compute_person_commissions_quarterly(p_agency_id, b.id, v_year, q)->'commission'->>'total_commission')::numeric AS q_comm
    FROM base_calc b
    CROSS JOIN generate_series(1, 4) AS q
  ),
  quarter_realized AS (
    SELECT ((period_month - 1) / 3) + 1 AS q, MAX(period_month) IS NOT NULL AS is_realized
    FROM public.producer_production
    WHERE agency_id = p_agency_id AND period_year = v_year
    GROUP BY ((period_month - 1) / 3) + 1
  ),
  q_annotated AS (
    SELECT qc.tm_id, qc.q, qc.q_comm, COALESCE(qr.is_realized, false) AS is_realized
    FROM q_commissions qc LEFT JOIN quarter_realized qr ON qr.q = qc.q
  ),
  comm_projection AS (
    SELECT tm_id,
      SUM(CASE WHEN is_realized THEN q_comm ELSE 0 END) AS realized_comm_sum,
      COUNT(*) FILTER (WHERE is_realized) AS realized_count,
      COUNT(*) FILTER (WHERE NOT is_realized) AS unrealized_count,
      CASE WHEN COUNT(*) FILTER (WHERE is_realized) > 0
        THEN SUM(CASE WHEN is_realized THEN q_comm ELSE 0 END) / COUNT(*) FILTER (WHERE is_realized)
        ELSE 0 END AS avg_realized_comm
    FROM q_annotated GROUP BY tm_id
  ),
  comm_annualized AS (
    SELECT cp.tm_id,
      cp.realized_comm_sum + (cp.avg_realized_comm * cp.unrealized_count) AS c_annual_comm,
      cp.realized_comm_sum, cp.avg_realized_comm, cp.realized_count, cp.unrealized_count
    FROM comm_projection cp
  ),
  quarter_bounds AS (
    SELECT q, make_date(v_year, ((q - 1) * 3) + 1, 1)::date AS q_start,
      (make_date(v_year, q * 3, 1) + INTERVAL '1 month - 1 day')::date AS q_end
    FROM generate_series(1, 4) AS q
  ),
  q_sp AS (
    SELECT wctd.team_member_id AS tm_id, qb.q, MAX(COALESCE(wctd.sales_points, 0)) AS q_max_sp
    FROM base_calc b
    CROSS JOIN quarter_bounds qb
    LEFT JOIN public.weekly_cpr_reports wr
      ON wr.agency_id = p_agency_id AND wr.week_ending_date >= qb.q_start
     AND wr.week_ending_date <= qb.q_end AND wr.week_ending_date <= p_week_end_date
    LEFT JOIN public.weekly_cpr_team_detail wctd
      ON wctd.weekly_cpr_report_id = wr.id AND wctd.team_member_id = b.id
    GROUP BY wctd.team_member_id, qb.q
  ),
  sp_annotated AS (
    SELECT qs.tm_id, qs.q, qs.q_max_sp, COALESCE(qr.is_realized, false) AS is_realized
    FROM q_sp qs LEFT JOIN quarter_realized qr ON qr.q = qs.q
    WHERE qs.tm_id IS NOT NULL
  ),
  sp_projection AS (
    SELECT tm_id,
      SUM(CASE WHEN is_realized THEN q_max_sp ELSE 0 END) AS realized_sp_sum,
      COUNT(*) FILTER (WHERE is_realized) AS realized_count,
      COUNT(*) FILTER (WHERE NOT is_realized) AS unrealized_count,
      CASE WHEN COUNT(*) FILTER (WHERE is_realized) > 0
        THEN SUM(CASE WHEN is_realized THEN q_max_sp ELSE 0 END) / COUNT(*) FILTER (WHERE is_realized)
        ELSE 0 END AS avg_realized_sp
    FROM sp_annotated GROUP BY tm_id
  ),
  sp_annualized AS (
    SELECT sp.tm_id, sp.realized_sp_sum + (sp.avg_realized_sp * sp.unrealized_count) AS c_annual_sp
    FROM sp_projection sp
  ),
  wh_calc AS (
    SELECT b.id AS tm_id, 40.0 AS hours,
      CASE WHEN b.role = 'Reception' THEN 1.00
           WHEN b.role IN ('Acquisition', 'Inside Sales') THEN 0.25 ELSE 0 END AS role_w,
      CASE WHEN b.work_location = 'in_office' THEN 1.00
           WHEN b.work_location = 'remote' THEN 0.50 ELSE 1.00 END AS location_w,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - b.start_date)::numeric / 7.0) / 52.0)) AS tenure_w,
      LEAST(1.00, 0.50
           + CASE WHEN b.license_pc  THEN 0.35 ELSE 0 END
           + CASE WHEN b.license_lh  THEN 0.10 ELSE 0 END
           + CASE WHEN b.license_ips THEN 0.05 ELSE 0 END) AS license_w
    FROM base_calc b
  ),
  wh_final AS (
    SELECT wh.tm_id, wh.hours * wh.role_w * wh.location_w * wh.tenure_w * wh.license_w AS weighted_hours,
      wh.role_w, wh.location_w, wh.tenure_w, wh.license_w
    FROM wh_calc wh
  ),
  combined AS (
    SELECT b.id AS tm_id, b.first_name, b.last_name, b.role, b.role_category, b.role_level,
      b.c_annual_base, b.c_base_tenure_mult, b.weekly_health_benefit_agency_paid,
      (b.c_annual_base * b.c_base_tenure_mult) AS c_annual_base_in_envelope,
      (b.c_annual_base * (1 + v_burden_multiplier) * (1 - b.c_base_tenure_mult)) AS c_annual_growth_budget,
      COALESCE(ca.c_annual_comm, 0) AS c_annual_comm,
      COALESCE(spa.c_annual_sp, 0) AS c_annual_sp,
      COALESCE(wf.weighted_hours, 0) AS weighted_hours,
      ca.realized_comm_sum, ca.avg_realized_comm, ca.realized_count AS comm_realized_q,
      ca.unrealized_count AS comm_unrealized_q,
      wf.role_w, wf.location_w, wf.tenure_w, wf.license_w
    FROM base_calc b
    LEFT JOIN comm_annualized ca ON ca.tm_id = b.id
    LEFT JOIN sp_annualized spa  ON spa.tm_id = b.id
    LEFT JOIN wh_final wf        ON wf.tm_id = b.id
  ),
  team_totals AS (
    SELECT
      SUM(c_annual_base) AS total_base,
      SUM(c_annual_base_in_envelope) AS total_base_in_envelope,
      SUM(c_annual_growth_budget) AS total_growth_budget,
      SUM(c_annual_comm) AS total_comm,
      SUM(c_annual_sp)   AS total_sp,
      SUM(weighted_hours) AS total_wh,
      SUM(COALESCE(weekly_health_benefit_agency_paid, 0) * 52) AS total_health_annual
    FROM combined
  ),
  bonus_pool_calc AS (
    SELECT
      tt.total_base, tt.total_base_in_envelope, tt.total_growth_budget,
      tt.total_comm, tt.total_sp, tt.total_wh, tt.total_health_annual,
      v_annual_envelope AS envelope,
      v_annual_carveouts AS carveouts,
      v_wc_annual AS wc,
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base_in_envelope - tt.total_comm - tt.total_health_annual
      ) AS annual_bonus_pool_gross,
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base_in_envelope - tt.total_comm - v_annual_carveouts - tt.total_health_annual
      ) AS annual_bonus_pool
    FROM team_totals tt
  ),
  bonus_pool AS (
    SELECT bpc.*,
      (bpc.total_base_in_envelope + bpc.total_comm + bpc.annual_bonus_pool + bpc.carveouts) * v_burden_multiplier AS burden
    FROM bonus_pool_calc bpc
  ),
  distributed AS (
    SELECT c.*,
      bp.annual_bonus_pool, bp.annual_bonus_pool_gross, bp.carveouts, bp.total_health_annual,
      bp.total_sp AS bp_total_sp, bp.total_wh AS bp_total_wh,
      bp.total_growth_budget AS bp_total_growth_budget,
      CASE WHEN bp.total_sp > 0 THEN c.c_annual_sp / bp.total_sp ELSE 0 END AS sp_share,
      CASE WHEN bp.total_wh > 0 THEN c.weighted_hours / bp.total_wh ELSE 0 END AS wh_share
    FROM combined c CROSS JOIN bonus_pool bp
  ),
  final AS (
    SELECT d.*,
      (0.65 * d.sp_share + 0.35 * d.wh_share) AS person_share,
      (0.65 * d.sp_share + 0.35 * d.wh_share) * d.annual_bonus_pool AS annual_bonus_gross,
      (0.65 * d.sp_share + 0.35 * d.wh_share) * d.annual_bonus_pool AS annual_bonus_net
    FROM distributed d
  )
  SELECT
    f.tm_id,
    f.first_name || ' ' || f.last_name,
    f.role, f.role_category, f.role_level,
    ROUND(f.c_annual_base, 2), ROUND(f.c_annual_base / 52.0, 2),
    ROUND(f.c_annual_comm, 2), ROUND(f.c_annual_comm / 52.0, 2),
    ROUND(f.c_annual_sp, 2),
    ROUND(f.sp_share * 100, 4),
    ROUND(f.weighted_hours, 4),
    ROUND(f.wh_share * 100, 4),
    ROUND(f.person_share * 100, 4),
    ROUND(f.annual_bonus_gross, 2),
    ROUND(f.annual_bonus_net, 2),
    ROUND(f.annual_bonus_net / 52.0, 2),
    ROUND(f.c_annual_base + f.c_annual_comm + f.annual_bonus_net, 2),
    ROUND((f.c_annual_base + f.c_annual_comm + f.annual_bonus_net) / 52.0, 2),
    jsonb_build_object(
      'realized_comm_sum',    f.realized_comm_sum,
      'avg_realized_comm',    f.avg_realized_comm,
      'comm_realized_q',      f.comm_realized_q,
      'comm_unrealized_q',    f.comm_unrealized_q,
      'weight_factors', jsonb_build_object(
        'hours_baseline', 40.0,
        'role_w', f.role_w, 'location_w', f.location_w,
        'tenure_w', f.tenure_w, 'license_w', f.license_w),
      'base_tenure_mult',     f.c_base_tenure_mult,
      'annual_base_in_envelope', ROUND(f.c_annual_base_in_envelope, 2),
      'annual_growth_budget', ROUND(f.c_annual_growth_budget, 2),
      'weekly_growth_budget', ROUND(f.c_annual_growth_budget / 52.0, 2),
      'annual_envelope',      v_annual_envelope,
      'annual_bonus_pool',    f.annual_bonus_pool,
      'annual_bonus_pool_gross', f.annual_bonus_pool_gross,
      'annual_carveouts',     f.carveouts,
      'team_total_base',      (SELECT total_base FROM team_totals),
      'team_total_base_in_envelope', (SELECT total_base_in_envelope FROM team_totals),
      'team_total_growth_budget',    (SELECT total_growth_budget FROM team_totals),
      'team_total_comm',      (SELECT total_comm FROM team_totals),
      'team_total_health_annual', f.total_health_annual,
      'team_total_burden',    (SELECT burden FROM bonus_pool),
      'team_wc_annual',       v_wc_annual,
      'burden_note',          'burden = 8% of (base_in_envelope + comm + bonus_pool + carveouts). Pool net of pre-pool carveouts + team health at envelope (2026-07-08). Remote location_w = 0.50 (2026-07-08).',
      'pool_basis',           v_pool_result->'basis',
      'schedule',             v_pool_result->'schedule',
      'carveouts_detail',     v_carveouts_result
    )
  FROM final f
  ORDER BY f.last_name;
END;
$function$;

-- 3) Update writer: no more health_subtracted column write, no more annual_health_subtracted in diag
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

  WITH src AS (SELECT * FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date)),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET base_salary_paid = s.weekly_base_salary,
        commission_paid  = s.weekly_commission_projected,
        bonus_gross      = ROUND(s.annual_bonus_gross / 52.0, 2),
        bonus_net        = s.weekly_bonus_net,
        residual_pool_diag = s.diagnostics || jsonb_build_object(
          'annual_base_salary', s.annual_base_salary,
          'annual_commission_projected', s.annual_commission_projected,
          'annual_bonus_gross', s.annual_bonus_gross,
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
    SET fully_loaded_annual         = w.fully_loaded_annual,
        attributed_revenue_annual   = w.attributed_revenue_annual,
        own_new_business_annualized = w.own_new_business_annualized,
        own_renewal_stack_credited  = w.own_renewal_stack_credited,
        retention_pool_share_annual = w.retention_pool_share_annual,
        retention_quality_multiplier = w.retention_quality_multiplier,
        coverage_bar                = w.coverage_bar,
        coverage_pct                = w.coverage_pct,
        coverage_status             = w.coverage_status,
        profitability_bar           = w.profitability_bar,
        profitability_pct           = w.profitability_pct,
        profitability_status        = w.profitability_status,
        lapse_rate_used             = w.lapse_rate_used,
        lapse_status                = w.lapse_status,
        renewal_stack_annual        = w.renewal_stack_annual,
        warning_bar           = w.warning_bar,
        warning_actual_annual = w.warning_actual_annual,
        warning_pct           = w.warning_pct,
        warning_status        = w.warning_status,
        warning_diag          = w.diag,
        updated_at            = now()
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

-- 4) Update test_residual_pool_v2 to drop annual_health_subtracted references
CREATE OR REPLACE FUNCTION public.test_residual_pool_v2(p_week_end_date date DEFAULT '2026-07-11'::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365'::uuid;
  v_envelope_full jsonb;
  v_envelope_annual numeric;
  v_envelope_weekly numeric;
  v_pool_pct numeric;
  v_phase text;
  v_basis_total numeric;
  v_pc_stripped numeric;
  v_lh_annualized numeric;
  v_smvc_dollars numeric;
  v_scorecard_dollars numeric;
  v_smvc_rate_applied numeric;
  v_strip_factor numeric;
  v_people jsonb;
  v_sum_base numeric;
  v_sum_comm numeric;
  v_sum_bonus_gross numeric;
  v_sum_bonus_net numeric;
  v_sum_sp_pct numeric;
  v_sum_rh_pct numeric;
  v_sum_person_pct numeric;
  v_implied_burden_wc numeric;
BEGIN
  v_envelope_full := compute_pool_basis_and_envelope(v_agency_id, p_week_end_date);
  v_envelope_annual := (v_envelope_full->'envelope'->>'annual_dollars')::numeric;
  v_envelope_weekly := (v_envelope_full->'envelope'->>'weekly_dollars')::numeric;
  v_pool_pct         := (v_envelope_full->'schedule'->>'pool_pct')::numeric;
  v_phase            := (v_envelope_full->'schedule'->>'phase')::text;
  v_basis_total      := (v_envelope_full->'basis'->>'total_basis_annual')::numeric;
  v_pc_stripped      := (v_envelope_full->'basis'->>'pc_stripped_annualized')::numeric;
  v_lh_annualized    := (v_envelope_full->'basis'->>'lh_annualized')::numeric;
  v_smvc_dollars     := (v_envelope_full->'basis'->>'on_time_smvc_dollars')::numeric;
  v_scorecard_dollars := (v_envelope_full->'basis'->>'on_time_scorecard_dollars')::numeric;
  v_smvc_rate_applied := (v_envelope_full->'basis'->>'smvc_rate_pc_applied')::numeric;
  v_strip_factor     := (v_envelope_full->'basis'->>'strip_factor')::numeric;

  SELECT jsonb_agg(row_data ORDER BY total_comp_annual DESC)
  INTO v_people
  FROM (
    SELECT
      jsonb_build_object(
        'name',                     full_name,
        'role',                     role || COALESCE(' / ' || role_level, ''),
        'annual_base',              ROUND(annual_base_salary, 0),
        'annual_commission',        ROUND(annual_commission_projected, 0),
        'sales_points_share_pct',   ROUND(sales_points_share_pct, 2),
        'retention_hours_share_pct', ROUND(retention_hours_share_pct, 2),
        'person_share_pct',         ROUND(person_share_pct, 2),
        'annual_bonus_gross',       ROUND(annual_bonus_gross, 0),
        'annual_bonus_net',         ROUND(annual_bonus_net, 0),
        'weekly_bonus_net',         ROUND(weekly_bonus_net, 2),
        'annual_total_comp',        ROUND(annual_total_comp, 0),
        'weekly_total_comp',        ROUND(weekly_total_comp, 2)
      ) AS row_data,
      annual_total_comp AS total_comp_annual
    FROM compute_weekly_comp_residual_pool(v_agency_id, p_week_end_date)
  ) sub;

  SELECT
    SUM(annual_base_salary),
    SUM(annual_commission_projected),
    SUM(annual_bonus_gross),
    SUM(annual_bonus_net),
    SUM(sales_points_share_pct),
    SUM(retention_hours_share_pct),
    SUM(person_share_pct)
  INTO
    v_sum_base, v_sum_comm, v_sum_bonus_gross, v_sum_bonus_net,
    v_sum_sp_pct, v_sum_rh_pct, v_sum_person_pct
  FROM compute_weekly_comp_residual_pool(v_agency_id, p_week_end_date);

  v_implied_burden_wc := v_envelope_annual - (v_sum_base + v_sum_comm + v_sum_bonus_gross);

  RETURN jsonb_build_object(
    'week_end_date', p_week_end_date,
    'envelope_summary', jsonb_build_object(
      'phase',                   v_phase,
      'pool_pct',                v_pool_pct,
      'basis_annual',            ROUND(v_basis_total, 0),
      'envelope_annual',         ROUND(v_envelope_annual, 0),
      'envelope_weekly',         ROUND(v_envelope_weekly, 2),
      'basis_lines', jsonb_build_object(
        'pc_stripped_annualized',  ROUND(v_pc_stripped, 0),
        'lh_annualized',           ROUND(v_lh_annualized, 0),
        'on_time_smvc_dollars',    ROUND(v_smvc_dollars, 0),
        'on_time_scorecard_dollars', ROUND(v_scorecard_dollars, 0),
        'smvc_rate_applied',       v_smvc_rate_applied,
        'strip_factor',            v_strip_factor
      )
    ),
    'per_person', v_people,
    'reconciliation', jsonb_build_object(
      'envelope_annual',           ROUND(v_envelope_annual, 0),
      'sum_base_annual',           ROUND(v_sum_base, 0),
      'sum_commission_annual',     ROUND(v_sum_comm, 0),
      'sum_bonus_gross_annual',    ROUND(v_sum_bonus_gross, 0),
      'sum_bonus_net_annual',      ROUND(v_sum_bonus_net, 0),
      'sum_total_paid_annual',     ROUND(v_sum_base + v_sum_comm + v_sum_bonus_net, 0),
      'implied_burden_and_wc',     ROUND(v_implied_burden_wc, 0),
      'expected_burden_and_wc',    ROUND((v_sum_base + v_sum_comm + v_sum_bonus_gross) * 0.08 + 500, 0),
      'sales_points_share_pct_sum', ROUND(v_sum_sp_pct, 2),
      'retention_hours_share_pct_sum', ROUND(v_sum_rh_pct, 2),
      'person_share_pct_sum',      ROUND(v_sum_person_pct, 2),
      'note', 'share sums should each land at 100.00. Health now at envelope; no per-person subtract. Remote location_w = 0.50 as of 2026-07-08.'
    ),
    'computed_at', now()
  );
END;
$function$;
