CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(team_member_id uuid, full_name text, role text, role_category text, role_level text, annual_base_salary numeric, weekly_base_salary numeric, annual_commission_projected numeric, weekly_commission_projected numeric, ytd_sales_points numeric, sales_points_share_pct numeric, weighted_hours_at_40 numeric, retention_hours_share_pct numeric, person_share_pct numeric, annual_bonus_gross numeric, annual_health_subtracted numeric, annual_bonus_net numeric, weekly_bonus_net numeric, annual_total_comp numeric, weekly_total_comp numeric, diagnostics jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_year               int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_current_quarter    int := ((EXTRACT(MONTH FROM p_week_end_date)::int - 1) / 3) + 1;
  v_pool_result        jsonb;
  v_annual_envelope    numeric;
  v_burden_multiplier  CONSTANT numeric := 0.08;   -- 8% per operational_rule
  v_wc_annual          CONSTANT numeric := 500.00; -- ~$500/yr team WC per operational_rule
  v_total_annual_base  numeric := 0;
  v_total_annual_comm  numeric := 0;
  v_total_burden       numeric;
  v_annual_bonus_pool  numeric;
  v_team_total_sp      numeric := 0;
  v_team_total_wh      numeric := 0;
BEGIN
  ------------------------------------------------------------------
  -- 1. Pool basis + annual envelope
  ------------------------------------------------------------------
  v_pool_result := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_annual_envelope := COALESCE(NULLIF(v_pool_result->'envelope'->>'annual_dollars','')::numeric, 0);

  ------------------------------------------------------------------
  -- 2. Per-person calc via CTE chain
  ------------------------------------------------------------------
  RETURN QUERY
  WITH roster AS (
    SELECT t.id, t.first_name, t.last_name, t.role, t.role_category, t.role_level,
           t.pay_type, t.pay_rate, t.work_location, t.start_date,
           t.license_pc, t.license_lh, t.license_ips,
           t.weekly_health_benefit_agency_paid
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND t.is_admin_backoffice = false
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND t.is_active = true
  ),
  -- Per-person annual base salary
  base_calc AS (
    SELECT r.*,
      CASE
        WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 52
        WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * 52
        ELSE 0
      END AS c_annual_base
    FROM roster r
  ),
  -- Per-quarter commission for each realized quarter (Q1..v_current_quarter-1) + current in-progress if data
  q_commissions AS (
    SELECT b.id AS tm_id, q,
      (public.compute_person_commissions_quarterly(p_agency_id, b.id, v_year, q)->'commission'->>'total_commission')::numeric AS q_comm
    FROM base_calc b
    CROSS JOIN generate_series(1, 4) AS q
  ),
  -- Which quarters have any producer_production data? (realized indicator)
  quarter_realized AS (
    SELECT
      ((period_month - 1) / 3) + 1 AS q,
      MAX(period_month) IS NOT NULL AS is_realized
    FROM public.producer_production
    WHERE agency_id = p_agency_id AND period_year = v_year
    GROUP BY ((period_month - 1) / 3) + 1
  ),
  q_annotated AS (
    SELECT qc.tm_id, qc.q, qc.q_comm,
      COALESCE(qr.is_realized, false) AS is_realized
    FROM q_commissions qc
    LEFT JOIN quarter_realized qr ON qr.q = qc.q
  ),
  -- Sum realized commissions + average-of-realized projection for unrealized
  comm_projection AS (
    SELECT tm_id,
      SUM(CASE WHEN is_realized THEN q_comm ELSE 0 END) AS realized_comm_sum,
      COUNT(*) FILTER (WHERE is_realized) AS realized_count,
      COUNT(*) FILTER (WHERE NOT is_realized) AS unrealized_count,
      CASE WHEN COUNT(*) FILTER (WHERE is_realized) > 0
        THEN SUM(CASE WHEN is_realized THEN q_comm ELSE 0 END) / COUNT(*) FILTER (WHERE is_realized)
        ELSE 0
      END AS avg_realized_comm
    FROM q_annotated
    GROUP BY tm_id
  ),
  comm_annualized AS (
    SELECT cp.tm_id,
      cp.realized_comm_sum + (cp.avg_realized_comm * cp.unrealized_count) AS c_annual_comm,
      cp.realized_comm_sum, cp.avg_realized_comm, cp.realized_count, cp.unrealized_count
    FROM comm_projection cp
  ),
  -- YTD sales_points: sum of per-quarter MAX(sales_points) for realized quarters, projected for unrealized
  quarter_bounds AS (
    SELECT
      q,
      make_date(v_year, ((q - 1) * 3) + 1, 1)::date AS q_start,
      (make_date(v_year, q * 3, 1) + INTERVAL '1 month - 1 day')::date AS q_end
    FROM generate_series(1, 4) AS q
  ),
  q_sp AS (
    SELECT
      wctd.team_member_id AS tm_id,
      qb.q,
      MAX(COALESCE(wctd.sales_points, 0)) AS q_max_sp
    FROM base_calc b
    CROSS JOIN quarter_bounds qb
    LEFT JOIN public.weekly_cpr_reports wr
      ON wr.agency_id = p_agency_id
     AND wr.week_ending_date >= qb.q_start
     AND wr.week_ending_date <= qb.q_end
     AND wr.week_ending_date <= p_week_end_date
    LEFT JOIN public.weekly_cpr_team_detail wctd
      ON wctd.weekly_cpr_report_id = wr.id
     AND wctd.team_member_id = b.id
    GROUP BY wctd.team_member_id, qb.q
  ),
  sp_annotated AS (
    SELECT qs.tm_id, qs.q, qs.q_max_sp,
      COALESCE(qr.is_realized, false) AS is_realized
    FROM q_sp qs
    LEFT JOIN quarter_realized qr ON qr.q = qs.q
    WHERE qs.tm_id IS NOT NULL
  ),
  sp_projection AS (
    SELECT tm_id,
      SUM(CASE WHEN is_realized THEN q_max_sp ELSE 0 END) AS realized_sp_sum,
      COUNT(*) FILTER (WHERE is_realized) AS realized_count,
      COUNT(*) FILTER (WHERE NOT is_realized) AS unrealized_count,
      CASE WHEN COUNT(*) FILTER (WHERE is_realized) > 0
        THEN SUM(CASE WHEN is_realized THEN q_max_sp ELSE 0 END) / COUNT(*) FILTER (WHERE is_realized)
        ELSE 0
      END AS avg_realized_sp
    FROM sp_annotated
    GROUP BY tm_id
  ),
  sp_annualized AS (
    SELECT sp.tm_id,
      sp.realized_sp_sum + (sp.avg_realized_sp * sp.unrealized_count) AS c_annual_sp
    FROM sp_projection sp
  ),
  -- Retention weighted hours at 40hr/wk pace (5-factor per operational_rule "Retention budget service surge split — permanent")
  wh_calc AS (
    SELECT b.id AS tm_id,
      40.0 AS hours,
      CASE WHEN b.role = 'Reception' THEN 1.00
           WHEN b.role IN ('Acquisition', 'Inside Sales') THEN 0.25
           ELSE 0 END AS role_w,
      CASE WHEN b.work_location = 'in_office' THEN 1.00
           WHEN b.work_location = 'remote' THEN 0.75
           ELSE 1.00 END AS location_w,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - b.start_date)::numeric / 7.0) / 52.0)) AS tenure_w,
      LEAST(1.00, 0.50
           + CASE WHEN b.license_pc  THEN 0.35 ELSE 0 END
           + CASE WHEN b.license_lh  THEN 0.10 ELSE 0 END
           + CASE WHEN b.license_ips THEN 0.05 ELSE 0 END) AS license_w
    FROM base_calc b
  ),
  wh_final AS (
    SELECT wh.tm_id,
      wh.hours * wh.role_w * wh.location_w * wh.tenure_w * wh.license_w AS weighted_hours,
      wh.role_w, wh.location_w, wh.tenure_w, wh.license_w
    FROM wh_calc wh
  ),
  -- Combined per-person data
  combined AS (
    SELECT b.id AS tm_id, b.first_name, b.last_name, b.role, b.role_category, b.role_level,
      b.c_annual_base, b.weekly_health_benefit_agency_paid,
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
  -- Team totals (for shares + burden)
  team_totals AS (
    SELECT
      SUM(c_annual_base) AS total_base,
      SUM(c_annual_comm) AS total_comm,
      SUM(c_annual_sp)   AS total_sp,
      SUM(weighted_hours) AS total_wh
    FROM combined
  ),
  -- NEW FORMULA (burden includes bonus):
  --   envelope = (base + comm + bonus) * (1 + burden_rate) + WC
  --   => bonus = (envelope - WC) / (1 + burden_rate) - base - comm
  bonus_pool_calc AS (
    SELECT
      tt.total_base, tt.total_comm, tt.total_sp, tt.total_wh,
      v_annual_envelope AS envelope,
      v_wc_annual AS wc,
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base
        - tt.total_comm
      ) AS annual_bonus_pool
    FROM team_totals tt
  ),
  bonus_pool AS (
    SELECT
      bpc.*,
      (bpc.total_base + bpc.total_comm + bpc.annual_bonus_pool) * v_burden_multiplier AS burden
    FROM bonus_pool_calc bpc
  ),
  -- Per-person shares + bonus math
  distributed AS (
    SELECT c.*,
      bp.annual_bonus_pool, bp.total_sp AS bp_total_sp, bp.total_wh AS bp_total_wh,
      CASE WHEN bp.total_sp > 0 THEN c.c_annual_sp / bp.total_sp ELSE 0 END AS sp_share,
      CASE WHEN bp.total_wh > 0 THEN c.weighted_hours / bp.total_wh ELSE 0 END AS wh_share
    FROM combined c CROSS JOIN bonus_pool bp
  ),
  final AS (
    SELECT d.*,
      (0.65 * d.sp_share + 0.35 * d.wh_share) AS person_share,
      (0.65 * d.sp_share + 0.35 * d.wh_share) * d.annual_bonus_pool AS annual_bonus_gross,
      COALESCE(d.weekly_health_benefit_agency_paid, 0) * 52 AS annual_health_subtract,
      GREATEST(0,
        (0.65 * d.sp_share + 0.35 * d.wh_share) * d.annual_bonus_pool
        - (COALESCE(d.weekly_health_benefit_agency_paid, 0) * 52)
      ) AS annual_bonus_net
    FROM distributed d
  )
  SELECT
    f.tm_id,
    f.first_name || ' ' || f.last_name,
    f.role,
    f.role_category,
    f.role_level,
    ROUND(f.c_annual_base, 2),
    ROUND(f.c_annual_base / 52.0, 2),
    ROUND(f.c_annual_comm, 2),
    ROUND(f.c_annual_comm / 52.0, 2),
    ROUND(f.c_annual_sp, 2),
    ROUND(f.sp_share * 100, 4),
    ROUND(f.weighted_hours, 4),
    ROUND(f.wh_share * 100, 4),
    ROUND(f.person_share * 100, 4),
    ROUND(f.annual_bonus_gross, 2),
    ROUND(f.annual_health_subtract, 2),
    ROUND(f.annual_bonus_net, 2),
    ROUND(f.annual_bonus_net / 52.0, 2),
    ROUND(f.c_annual_base + f.c_annual_comm + f.annual_bonus_net, 2),
    ROUND((f.c_annual_base + f.c_annual_comm + f.annual_bonus_net) / 52.0, 2),
    jsonb_build_object(
      'realized_comm_sum',    f.realized_comm_sum,
      'avg_realized_comm',    f.avg_realized_comm,
      'comm_realized_q',      f.comm_realized_q,
      'comm_unrealized_q',    f.comm_unrealized_q,
      'weight_factors',       jsonb_build_object(
                                'hours_baseline', 40.0,
                                'role_w', f.role_w,
                                'location_w', f.location_w,
                                'tenure_w', f.tenure_w,
                                'license_w', f.license_w),
      'annual_envelope',      v_annual_envelope,
      'annual_bonus_pool',    f.annual_bonus_pool,
      'team_total_base',      (SELECT total_base FROM team_totals),
      'team_total_comm',      (SELECT total_comm FROM team_totals),
      'team_total_burden',    (SELECT burden FROM bonus_pool),
      'team_wc_annual',       v_wc_annual,
      'burden_note',          'burden = 8% of (base + comm + bonus_pool) — includes bonus',
      'pool_basis',           v_pool_result->'basis',
      'schedule',             v_pool_result->'schedule'
    )
  FROM final f
  ORDER BY f.last_name;
END;
$function$;