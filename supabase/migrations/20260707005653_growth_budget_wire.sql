-- ============================================================================
-- Growth Budget wire — 2026-07-06
-- ============================================================================
-- Applies the new_hire_integration tenure ramp to base pay in envelope math,
-- exposes the shielded portion as "growth budget" via views + forecast fn,
-- adds annual ceiling column on agency table for Peter to set later.
--
-- Impact: bonus pool math no longer loads new-hire base pay at 100% during
-- their 52-week ramp. Shielded portion becomes growth budget (real $ paid
-- to person, but not weighing on existing team's bonus pool).
--
-- Retention weighted hours tenure ramp already applied in prior version;
-- this migration adds the base-pay side. Full base still paid to person —
-- ramp only affects residual-pool math.
-- ============================================================================

-- 1. Ceiling column on agency
ALTER TABLE public.agency
  ADD COLUMN IF NOT EXISTS growth_budget_ceiling_annual NUMERIC;

COMMENT ON COLUMN public.agency.growth_budget_ceiling_annual IS
  'Annual ceiling for growth budget spend (real dollars paid to new hires during 52-wk tenure ramp, shielded from residual-pool math). NULL = no ceiling set. Warnings surface when projected annualized YTD exceeds ceiling.';

-- ============================================================================
-- 2. compute_weekly_comp_residual_pool — apply tenure ramp to base pay
-- ============================================================================
CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(team_member_id uuid, full_name text, role text, role_category text, role_level text, annual_base_salary numeric, weekly_base_salary numeric, annual_commission_projected numeric, weekly_commission_projected numeric, ytd_sales_points numeric, sales_points_share_pct numeric, weighted_hours_at_40 numeric, retention_hours_share_pct numeric, person_share_pct numeric, annual_bonus_gross numeric, annual_health_subtracted numeric, annual_bonus_net numeric, weekly_bonus_net numeric, annual_total_comp numeric, weekly_total_comp numeric, diagnostics jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_year               int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_pool_result        jsonb;
  v_annual_envelope    numeric;
  v_burden_multiplier  CONSTANT numeric := 0.08;   -- 8% per operational_rule
  v_wc_annual          CONSTANT numeric := 500.00; -- ~$500/yr team WC
BEGIN
  v_pool_result := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_annual_envelope := COALESCE(NULLIF(v_pool_result->'envelope'->>'annual_dollars','')::numeric, 0);

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
  base_calc AS (
    SELECT r.*,
      CASE
        WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 52
        WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * 52
        ELSE 0
      END AS c_annual_base,
      -- NEW: tenure multiplier for base pay in envelope math
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
  combined AS (
    SELECT b.id AS tm_id, b.first_name, b.last_name, b.role, b.role_category, b.role_level,
      b.c_annual_base, b.c_base_tenure_mult, b.weekly_health_benefit_agency_paid,
      -- NEW: base_in_envelope = ramped base for pool math
      (b.c_annual_base * b.c_base_tenure_mult) AS c_annual_base_in_envelope,
      -- NEW: growth budget = full base * burden * (1 - tenure)
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
      SUM(c_annual_base) AS total_base,                        -- full base (for output/paycheck reference)
      SUM(c_annual_base_in_envelope) AS total_base_in_envelope,-- ramped base (for envelope math) — NEW
      SUM(c_annual_growth_budget) AS total_growth_budget,      -- shielded portion — NEW
      SUM(c_annual_comm) AS total_comm,
      SUM(c_annual_sp)   AS total_sp,
      SUM(weighted_hours) AS total_wh
    FROM combined
  ),
  -- Bonus pool now uses ramped base
  --   envelope = (base_in_envelope + comm + bonus) * (1 + burden_rate) + WC
  --   => bonus = (envelope - WC) / (1 + burden_rate) - base_in_envelope - comm
  bonus_pool_calc AS (
    SELECT
      tt.total_base, tt.total_base_in_envelope, tt.total_growth_budget,
      tt.total_comm, tt.total_sp, tt.total_wh,
      v_annual_envelope AS envelope,
      v_wc_annual AS wc,
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base_in_envelope
        - tt.total_comm
      ) AS annual_bonus_pool
    FROM team_totals tt
  ),
  bonus_pool AS (
    SELECT
      bpc.*,
      (bpc.total_base_in_envelope + bpc.total_comm + bpc.annual_bonus_pool) * v_burden_multiplier AS burden
    FROM bonus_pool_calc bpc
  ),
  distributed AS (
    SELECT c.*,
      bp.annual_bonus_pool, bp.total_sp AS bp_total_sp, bp.total_wh AS bp_total_wh,
      bp.total_growth_budget AS bp_total_growth_budget,
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
    ROUND(f.c_annual_base, 2),                    -- full base (unchanged, what person gets paid)
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
      'base_tenure_mult',     f.c_base_tenure_mult,
      'annual_base_in_envelope', ROUND(f.c_annual_base_in_envelope, 2),
      'annual_growth_budget', ROUND(f.c_annual_growth_budget, 2),
      'weekly_growth_budget', ROUND(f.c_annual_growth_budget / 52.0, 2),
      'annual_envelope',      v_annual_envelope,
      'annual_bonus_pool',    f.annual_bonus_pool,
      'team_total_base',      (SELECT total_base FROM team_totals),
      'team_total_base_in_envelope', (SELECT total_base_in_envelope FROM team_totals),
      'team_total_growth_budget',    (SELECT total_growth_budget FROM team_totals),
      'team_total_comm',      (SELECT total_comm FROM team_totals),
      'team_total_burden',    (SELECT burden FROM bonus_pool),
      'team_wc_annual',       v_wc_annual,
      'burden_note',          'burden = 8% of (base_in_envelope + comm + bonus_pool). Base uses tenure ramp.',
      'pool_basis',           v_pool_result->'basis',
      'schedule',             v_pool_result->'schedule'
    )
  FROM final f
  ORDER BY f.last_name;
END;
$function$;

-- ============================================================================
-- 3. get_current_bonus_pool — add growth budget fields to output
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_current_bonus_pool(p_agency_id uuid, p_week_end_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_target_date date;
  v_diag        jsonb;
  v_schedule_pct numeric;
BEGIN
  IF p_week_end_date IS NULL THEN
    v_target_date := CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7);
    IF NOT EXISTS (
      SELECT 1 FROM public.team_comp_pool_schedule
      WHERE agency_id = p_agency_id AND week_end_date = v_target_date
    ) THEN
      SELECT MIN(week_end_date) INTO v_target_date
      FROM public.team_comp_pool_schedule
      WHERE agency_id = p_agency_id AND week_end_date >= CURRENT_DATE;
    END IF;
  ELSE
    v_target_date := p_week_end_date;
  END IF;

  SELECT pool_pct INTO v_schedule_pct
  FROM public.team_comp_pool_schedule
  WHERE agency_id = p_agency_id AND week_end_date = v_target_date;

  IF v_schedule_pct IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id',     p_agency_id,
      'week_end_date', v_target_date,
      'error',         format('no team_comp_pool_schedule row for week ending %s', v_target_date),
      'computed_at',   now()
    );
  END IF;

  SELECT diagnostics INTO v_diag
  FROM public.compute_weekly_comp_residual_pool(p_agency_id, v_target_date)
  LIMIT 1;

  IF v_diag IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id',     p_agency_id,
      'week_end_date', v_target_date,
      'error',         'no roster rows returned - check active team',
      'computed_at',   now()
    );
  END IF;

  RETURN jsonb_build_object(
    'agency_id',         p_agency_id,
    'week_end_date',     v_target_date,
    'annual_envelope',   (v_diag->>'annual_envelope')::numeric,
    'annual_bonus_pool', ROUND((v_diag->>'annual_bonus_pool')::numeric, 2),
    'weekly_bonus_pool', ROUND((v_diag->>'annual_bonus_pool')::numeric / 52.0, 2),
    'team_total_base',   (v_diag->>'team_total_base')::numeric,
    'team_total_base_in_envelope', (v_diag->>'team_total_base_in_envelope')::numeric,
    'team_total_growth_budget',    (v_diag->>'team_total_growth_budget')::numeric,
    'team_total_comm',   ROUND((v_diag->>'team_total_comm')::numeric, 2),
    'team_total_burden', ROUND((v_diag->>'team_total_burden')::numeric, 2),
    'pool_basis',        v_diag->'pool_basis',
    'schedule',          v_diag->'schedule',
    'computed_at',       now()
  );
END;
$function$;

-- ============================================================================
-- 4. v_growth_budget_current — per-person snapshot for active ramping team
-- ============================================================================
CREATE OR REPLACE VIEW public.v_growth_budget_current AS
WITH ramping_team AS (
  SELECT
    t.agency_id,
    t.id AS team_member_id,
    t.first_name || ' ' || t.last_name AS full_name,
    t.start_date,
    (CURRENT_DATE - t.start_date)::int AS days_since_start,
    FLOOR((CURRENT_DATE - t.start_date)::numeric / 7.0)::int AS weeks_since_start,
    LEAST(1.00, GREATEST(0, FLOOR((CURRENT_DATE - t.start_date)::numeric / 7.0) / 52.0)) AS tenure_multiplier,
    CASE
      WHEN t.pay_type = 'SALARY' AND t.pay_rate IS NOT NULL THEN t.pay_rate * 52
      WHEN t.pay_type = 'HOURLY' AND t.pay_rate IS NOT NULL THEN t.pay_rate * 40 * 52
      ELSE 0
    END AS annual_base
  FROM public.team t
  WHERE t.category = 'agency'
    AND t.is_admin_backoffice = false
    AND COALESCE(t.role_level, '') <> 'Owner'
    AND t.is_active = true
    AND (CURRENT_DATE - t.start_date) < 52 * 7
    AND t.start_date IS NOT NULL
)
SELECT
  rt.agency_id,
  rt.team_member_id,
  rt.full_name,
  rt.start_date,
  rt.weeks_since_start,
  ROUND(rt.tenure_multiplier, 4) AS tenure_multiplier,
  ROUND(rt.annual_base, 2) AS annual_base,
  ROUND(rt.annual_base * 1.08 / 52.0, 2) AS fully_loaded_weekly,
  ROUND(rt.annual_base * 1.08 * rt.tenure_multiplier / 52.0, 2) AS pool_weight_weekly,
  ROUND(rt.annual_base * 1.08 * (1 - rt.tenure_multiplier) / 52.0, 2) AS growth_budget_weekly,
  ROUND(rt.annual_base * 1.08 * (1 - rt.tenure_multiplier), 2) AS growth_budget_remaining_annualized,
  (52 - rt.weeks_since_start) AS weeks_remaining_in_ramp
FROM ramping_team rt
ORDER BY rt.start_date DESC;

COMMENT ON VIEW public.v_growth_budget_current IS
  'Current-week snapshot of growth budget per active ramping team member (tenure < 52 weeks). Real dollars paid to person during ramp, shielded from residual-pool envelope math.';

-- ============================================================================
-- 5. v_growth_budget_ytd — YTD sum per person + agency total
-- ============================================================================
CREATE OR REPLACE VIEW public.v_growth_budget_ytd AS
WITH weeks_ytd AS (
  SELECT generate_series(
    date_trunc('year', CURRENT_DATE)::date,
    CURRENT_DATE,
    '7 days'::interval
  )::date AS week_start
),
team_all AS (
  SELECT
    t.agency_id,
    t.id AS team_member_id,
    t.first_name || ' ' || t.last_name AS full_name,
    t.start_date,
    CASE
      WHEN t.pay_type = 'SALARY' AND t.pay_rate IS NOT NULL THEN t.pay_rate * 52
      WHEN t.pay_type = 'HOURLY' AND t.pay_rate IS NOT NULL THEN t.pay_rate * 40 * 52
      ELSE 0
    END AS annual_base
  FROM public.team t
  WHERE t.category = 'agency'
    AND t.is_admin_backoffice = false
    AND COALESCE(t.role_level, '') <> 'Owner'
    AND t.is_active = true
    AND t.start_date IS NOT NULL
),
weekly_gb AS (
  SELECT
    ta.agency_id,
    ta.team_member_id,
    ta.full_name,
    ta.start_date,
    w.week_start,
    LEAST(1.00, GREATEST(0, FLOOR((w.week_start - ta.start_date)::numeric / 7.0) / 52.0)) AS tenure_mult,
    ta.annual_base * 1.08 * (1 - LEAST(1.00, GREATEST(0, FLOOR((w.week_start - ta.start_date)::numeric / 7.0) / 52.0))) / 52.0 AS gb_weekly
  FROM team_all ta
  CROSS JOIN weeks_ytd w
  WHERE w.week_start >= ta.start_date
)
SELECT
  agency_id,
  team_member_id,
  full_name,
  start_date,
  ROUND(SUM(gb_weekly), 2) AS growth_budget_ytd,
  COUNT(*) FILTER (WHERE gb_weekly > 0) AS weeks_ramping_ytd
FROM weekly_gb
GROUP BY agency_id, team_member_id, full_name, start_date
HAVING SUM(gb_weekly) > 0
ORDER BY SUM(gb_weekly) DESC;

COMMENT ON VIEW public.v_growth_budget_ytd IS
  'YTD sum of weekly growth budget per person. SUM across rows for agency-total YTD. Only rows with >0 growth budget included.';

-- ============================================================================
-- 6. get_growth_budget_forecast — projected growth budget for hypothetical hire
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_growth_budget_forecast(
  p_annual_base numeric,
  p_start_date date DEFAULT CURRENT_DATE,
  p_forecast_weeks int DEFAULT 78
)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_fully_loaded_annual numeric := p_annual_base * 1.08;
  v_fully_loaded_weekly numeric := v_fully_loaded_annual / 52.0;
  v_weeks jsonb;
  v_year_1_total numeric;
  v_quarters jsonb;
BEGIN
  -- Per-week series
  WITH weekly AS (
    SELECT
      w AS week_num,
      p_start_date + (w * 7) AS week_ending,
      LEAST(1.00, w::numeric / 52.0) AS tenure_mult,
      v_fully_loaded_weekly AS fully_loaded_weekly,
      v_fully_loaded_weekly * LEAST(1.00, w::numeric / 52.0) AS pool_weight_weekly,
      v_fully_loaded_weekly * (1 - LEAST(1.00, w::numeric / 52.0)) AS growth_budget_weekly
    FROM generate_series(1, p_forecast_weeks) AS w
  )
  SELECT jsonb_agg(jsonb_build_object(
    'week_num', week_num,
    'week_ending', week_ending,
    'tenure_multiplier', ROUND(tenure_mult, 4),
    'fully_loaded_weekly', ROUND(fully_loaded_weekly, 2),
    'pool_weight_weekly', ROUND(pool_weight_weekly, 2),
    'growth_budget_weekly', ROUND(growth_budget_weekly, 2)
  ) ORDER BY week_num)
  INTO v_weeks
  FROM weekly;

  -- Year-1 total (rule of thumb: linear ramp averages 50%)
  SELECT ROUND(SUM(gb), 2)
  INTO v_year_1_total
  FROM (
    SELECT v_fully_loaded_weekly * (1 - LEAST(1.00, w::numeric / 52.0)) AS gb
    FROM generate_series(1, 52) AS w
  ) sub;

  -- Quarterly rollup (from start date)
  WITH quarterly AS (
    SELECT
      ((w - 1) / 13) + 1 AS q_num,
      MIN(p_start_date + (w * 7)) AS q_start,
      MAX(p_start_date + (w * 7)) AS q_end,
      ROUND(SUM(v_fully_loaded_weekly * (1 - LEAST(1.00, w::numeric / 52.0))), 2) AS q_growth_budget,
      ROUND(SUM(v_fully_loaded_weekly * LEAST(1.00, w::numeric / 52.0)), 2) AS q_pool_weight
    FROM generate_series(1, LEAST(p_forecast_weeks, 52)) AS w
    GROUP BY ((w - 1) / 13) + 1
  )
  SELECT jsonb_agg(jsonb_build_object(
    'quarter_num', q_num,
    'quarter_start', q_start,
    'quarter_end', q_end,
    'growth_budget', q_growth_budget,
    'pool_weight', q_pool_weight
  ) ORDER BY q_num)
  INTO v_quarters
  FROM quarterly;

  RETURN jsonb_build_object(
    'inputs', jsonb_build_object(
      'annual_base', p_annual_base,
      'start_date', p_start_date,
      'forecast_weeks', p_forecast_weeks,
      'burden_multiplier', 1.08
    ),
    'summary', jsonb_build_object(
      'fully_loaded_annual', ROUND(v_fully_loaded_annual, 2),
      'fully_loaded_weekly', ROUND(v_fully_loaded_weekly, 2),
      'year_1_growth_budget_total', v_year_1_total,
      'year_1_growth_budget_rule_of_thumb', ROUND(v_fully_loaded_annual * 0.5, 2),
      'ramp_complete_date', p_start_date + (52 * 7)
    ),
    'quarters', v_quarters,
    'weeks', v_weeks,
    'computed_at', now()
  );
END;
$function$;

COMMENT ON FUNCTION public.get_growth_budget_forecast IS
  'Forecast growth budget for a hypothetical new hire. Returns per-week + quarterly + summary breakdown. Use for hiring planning.';
