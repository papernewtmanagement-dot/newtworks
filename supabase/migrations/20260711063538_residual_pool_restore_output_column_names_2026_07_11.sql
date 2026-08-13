-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-11 06:35:38 UTC (ledger name: residual_pool_restore_output_column_names_2026_07_11) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260711063538.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- compute_warning_trigger + other downstream callers reference the ORIGINAL output columns.
-- Restore column names on RETURNS TABLE (fix the ambiguity in the BODY via aliases only).
DROP FUNCTION IF EXISTS public.compute_weekly_comp_residual_pool(uuid, date);

CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(
   team_member_id uuid, full_name text, role text, role_category text, role_level text,
   annual_base_salary numeric, weekly_base_salary numeric,
   annual_commission_projected numeric, weekly_commission_projected numeric,
   ytd_sales_points numeric, sales_points_share_pct numeric,
   weighted_hours_at_40 numeric, retention_hours_share_pct numeric,
   person_share_pct numeric,
   annual_bonus numeric, weekly_bonus numeric,
   weekly_sales_pool_share numeric, weekly_retention_pool_share numeric,
   annual_total_comp numeric, weekly_total_comp numeric,
   diagnostics jsonb
 )
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_year               int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_quarter            int := EXTRACT(QUARTER FROM p_week_end_date)::int;
  v_q_start            date := make_date(v_year, ((v_quarter - 1) * 3) + 1, 1);
  v_pool_result        jsonb;
  v_carveouts_result   jsonb;
  v_annual_envelope    numeric;
  v_annual_carveouts   numeric;
  v_burden_multiplier  CONSTANT numeric := 0.08;
  v_wc_annual          CONSTANT numeric := 500.00;
  v_sales_weight       CONSTANT numeric := 0.65;
  v_retention_weight   CONSTANT numeric := 0.35;
BEGIN
  v_pool_result      := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_carveouts_result := public.compute_pool_carveouts(p_agency_id, p_week_end_date);
  v_annual_envelope  := COALESCE(NULLIF(v_pool_result->'envelope'->>'annual_dollars','')::numeric, 0);
  v_annual_carveouts := COALESCE(NULLIF(v_carveouts_result->>'total_annual_carveouts','')::numeric, 0);

  RETURN QUERY
  WITH roster AS (
    SELECT et.team_id AS id, et.first_name, et.last_name,
           et.role         AS r_role,
           et.role_category AS r_role_category,
           et.role_level   AS r_role_level,
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
  quarter_bounds AS (
    SELECT q, make_date(v_year, ((q - 1) * 3) + 1, 1)::date AS q_start,
      (make_date(v_year, q * 3, 1) + INTERVAL '1 month - 1 day')::date AS q_end
    FROM generate_series(1, 4) AS q
  ),
  quarter_realized AS (
    SELECT ((period_month - 1) / 3) + 1 AS q, MAX(period_month) IS NOT NULL AS is_realized
    FROM public.producer_production
    WHERE agency_id = p_agency_id AND period_year = v_year
    GROUP BY ((period_month - 1) / 3) + 1
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
    SELECT sp.tm_id, sp.realized_sp_sum + (sp.avg_realized_sp * sp.unrealized_count) AS c_annual_sp,
      sp.realized_sp_sum, sp.avg_realized_sp, sp.realized_count, sp.unrealized_count
    FROM sp_projection sp
  ),
  curr_sp AS (
    SELECT b.id AS tm_id,
      COALESCE((
        SELECT wctd_c.sales_points
        FROM public.weekly_cpr_reports wr_c
        JOIN public.weekly_cpr_team_detail wctd_c ON wctd_c.weekly_cpr_report_id = wr_c.id
        WHERE wr_c.agency_id = p_agency_id
          AND wr_c.week_ending_date = p_week_end_date
          AND wctd_c.team_member_id = b.id
        LIMIT 1
      ), 0) AS qtd_sp
    FROM base_calc b
  ),
  prior_sp AS (
    SELECT b.id AS tm_id,
      COALESCE((
        SELECT wctd_p.sales_points
        FROM public.weekly_cpr_reports wr_p
        JOIN public.weekly_cpr_team_detail wctd_p ON wctd_p.weekly_cpr_report_id = wr_p.id
        WHERE wr_p.agency_id = p_agency_id
          AND wr_p.week_ending_date < p_week_end_date
          AND wr_p.week_ending_date >= v_q_start
          AND wctd_p.team_member_id = b.id
        ORDER BY wr_p.week_ending_date DESC
        LIMIT 1
      ), 0) AS prior_qtd_sp
    FROM base_calc b
  ),
  weekly_comm AS (
    SELECT cur.tm_id, GREATEST(0, cur.qtd_sp - prior.prior_qtd_sp) AS weekly_commission
    FROM curr_sp cur JOIN prior_sp prior ON prior.tm_id = cur.tm_id
  ),
  wh_calc AS (
    SELECT b.id AS tm_id, 40.0 AS hours,
      CASE WHEN b.r_role = 'Reception' THEN 1.00
           WHEN b.r_role IN ('Acquisition', 'Inside Sales') THEN 0.25 ELSE 0 END AS role_w,
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
    SELECT b.id AS tm_id, b.first_name, b.last_name,
      b.r_role AS c_role,
      b.r_role_category AS c_role_category,
      b.r_role_level AS c_role_level,
      b.c_annual_base, b.c_base_tenure_mult, b.weekly_health_benefit_agency_paid, b.pay_type, b.pay_rate,
      (b.c_annual_base * b.c_base_tenure_mult) AS c_annual_base_in_envelope,
      (b.c_annual_base * (1 + v_burden_multiplier) * (1 - b.c_base_tenure_mult)) AS c_annual_growth_budget,
      COALESCE(spa.c_annual_sp, 0) AS c_annual_comm,
      COALESCE(spa.c_annual_sp, 0) AS c_annual_sp,
      COALESCE(wc.weekly_commission, 0) AS c_weekly_comm,
      COALESCE(cs.qtd_sp, 0) AS c_qtd_sp,
      COALESCE(wf.weighted_hours, 0) AS weighted_hours,
      spa.realized_sp_sum AS realized_comm_sum,
      spa.avg_realized_sp AS avg_realized_comm,
      spa.realized_count  AS comm_realized_q,
      spa.unrealized_count AS comm_unrealized_q,
      wf.role_w, wf.location_w, wf.tenure_w, wf.license_w
    FROM base_calc b
    LEFT JOIN sp_annualized spa ON spa.tm_id = b.id
    LEFT JOIN weekly_comm   wc  ON wc.tm_id  = b.id
    LEFT JOIN curr_sp       cs  ON cs.tm_id  = b.id
    LEFT JOIN wh_final      wf  ON wf.tm_id  = b.id
  ),
  team_totals AS (
    SELECT
      SUM(c.c_annual_base) AS total_base,
      SUM(c.c_annual_base_in_envelope) AS total_base_in_envelope,
      SUM(c.c_annual_growth_budget) AS total_growth_budget,
      SUM(c.c_annual_comm) AS total_comm,
      SUM(c.c_annual_sp)   AS total_sp,
      SUM(CASE WHEN c.c_role_category = 'Sales' THEN c.c_annual_sp ELSE 0 END) AS total_sp_sales_only,
      SUM(c.weighted_hours) AS total_wh,
      SUM(COALESCE(c.weekly_health_benefit_agency_paid, 0) * 52) AS total_health_annual
    FROM combined c
  ),
  bonus_pool_calc AS (
    SELECT
      tt.total_base, tt.total_base_in_envelope, tt.total_growth_budget,
      tt.total_comm, tt.total_sp, tt.total_sp_sales_only, tt.total_wh, tt.total_health_annual,
      v_annual_envelope AS envelope,
      v_annual_carveouts AS carveouts,
      v_wc_annual AS wc,
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base_in_envelope - tt.total_health_annual
      ) AS annual_bonus_pool_gross,
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base_in_envelope - tt.total_health_annual - v_annual_carveouts
      ) AS annual_bonus_pool
    FROM team_totals tt
  ),
  bonus_pool AS (
    SELECT bpc.*,
      bpc.annual_bonus_pool * v_sales_weight     AS annual_sales_pool_pre_comm,
      bpc.annual_bonus_pool * v_retention_weight AS annual_retention_pool,
      GREATEST(0, bpc.annual_bonus_pool * v_sales_weight - bpc.total_comm) AS annual_sales_pool,
      (bpc.total_base_in_envelope + bpc.total_comm + bpc.annual_bonus_pool + bpc.carveouts) * v_burden_multiplier AS burden
    FROM bonus_pool_calc bpc
  ),
  distributed AS (
    SELECT c.*,
      bp.annual_bonus_pool, bp.annual_bonus_pool_gross, bp.carveouts, bp.total_health_annual,
      bp.annual_sales_pool, bp.annual_sales_pool_pre_comm, bp.annual_retention_pool,
      bp.total_sp AS bp_total_sp, bp.total_sp_sales_only AS bp_total_sp_sales_only,
      bp.total_wh AS bp_total_wh, bp.total_growth_budget AS bp_total_growth_budget,
      CASE WHEN bp.total_sp_sales_only > 0 AND c.c_role_category = 'Sales'
           THEN c.c_annual_sp / bp.total_sp_sales_only
           ELSE 0 END AS sp_share,
      CASE WHEN bp.total_wh > 0 THEN c.weighted_hours / bp.total_wh ELSE 0 END AS wh_share
    FROM combined c CROSS JOIN bonus_pool bp
  ),
  final AS (
    SELECT d.*,
      d.sp_share * d.annual_sales_pool     AS annual_sales_share,
      d.wh_share * d.annual_retention_pool AS annual_retention_share,
      (d.sp_share * d.annual_sales_pool + d.wh_share * d.annual_retention_pool) AS annual_bonus,
      CASE WHEN d.annual_bonus_pool > 0
           THEN (d.sp_share * d.annual_sales_pool + d.wh_share * d.annual_retention_pool) / d.annual_bonus_pool
           ELSE 0 END AS person_share
    FROM distributed d
  )
  SELECT
    f.tm_id,
    (f.first_name || ' ' || f.last_name)::text,
    f.c_role::text,
    f.c_role_category::text,
    f.c_role_level::text,
    ROUND(f.c_annual_base, 2), ROUND(f.c_annual_base / 52.0, 2),
    ROUND(f.c_annual_comm, 2),
    ROUND(f.c_weekly_comm, 2),
    ROUND(f.c_qtd_sp, 2),
    ROUND(f.sp_share * 100, 4),
    ROUND(f.weighted_hours, 4),
    ROUND(f.wh_share * 100, 4),
    ROUND(f.person_share * 100, 4),
    ROUND(f.annual_bonus, 2),
    ROUND(f.annual_bonus / 52.0, 2),
    ROUND(f.annual_sales_share / 52.0, 2),
    ROUND(f.annual_retention_share / 52.0, 2),
    ROUND(f.c_annual_base + f.c_annual_comm + f.annual_bonus, 2),
    ROUND((f.c_annual_base + f.c_annual_comm + f.annual_bonus) / 52.0, 2),
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
      'annual_sales_pool_pre_comm', f.annual_sales_pool_pre_comm,
      'annual_sales_pool',    f.annual_sales_pool,
      'annual_retention_pool', f.annual_retention_pool,
      'weekly_sales_pool',    ROUND(f.annual_sales_pool / 52.0, 2),
      'weekly_sales_pool_pre_comm', ROUND(f.annual_sales_pool_pre_comm / 52.0, 2),
      'weekly_retention_pool', ROUND(f.annual_retention_pool / 52.0, 2),
      'annual_carveouts',     f.carveouts,
      'team_total_base',      (SELECT total_base FROM team_totals),
      'team_total_base_in_envelope', (SELECT total_base_in_envelope FROM team_totals),
      'team_total_growth_budget',    (SELECT total_growth_budget FROM team_totals),
      'team_total_comm',      (SELECT total_comm FROM team_totals),
      'team_total_sp',        (SELECT total_sp FROM team_totals),
      'team_total_sp_sales_only', (SELECT total_sp_sales_only FROM team_totals),
      'team_total_health_annual', f.total_health_annual,
      'team_total_burden',    (SELECT burden FROM bonus_pool),
      'team_wc_annual',       v_wc_annual,
      'sales_weight',         v_sales_weight,
      'retention_weight',     v_retention_weight,
      'burden_multiplier',    v_burden_multiplier,
      'commission_semantic',  'sp_delta_this_week',
      'person_pay_type',      f.pay_type,
      'person_pay_rate',      f.pay_rate,
      'pool_basis',           v_pool_result->'basis',
      'schedule',             v_pool_result->'schedule',
      'envelope',             v_pool_result->'envelope',
      'carveouts_detail',     v_carveouts_result
    )
  FROM final f
  ORDER BY f.last_name;
END;
$function$;
