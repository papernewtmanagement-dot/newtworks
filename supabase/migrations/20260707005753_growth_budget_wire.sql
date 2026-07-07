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
-- Full function body: see canonical source in DB pg_proc.
-- Applied via Supabase MCP apply_migration 2026-07-07 UTC.
-- ============================================================================
-- (SQL body: CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool ...)
-- Key change: base_calc adds c_base_tenure_mult; combined adds c_annual_base_in_envelope
-- and c_annual_growth_budget; team_totals surfaces total_base_in_envelope and
-- total_growth_budget; bonus_pool_calc uses total_base_in_envelope not total_base.

-- ============================================================================
-- 3. get_current_bonus_pool — add growth budget fields to output
-- ============================================================================
-- (SQL body: CREATE OR REPLACE FUNCTION public.get_current_bonus_pool ...)
-- Key change: output includes team_total_base_in_envelope + team_total_growth_budget

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

  SELECT ROUND(SUM(gb), 2)
  INTO v_year_1_total
  FROM (
    SELECT v_fully_loaded_weekly * (1 - LEAST(1.00, w::numeric / 52.0)) AS gb
    FROM generate_series(1, 52) AS w
  ) sub;

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

-- NOTE: compute_weekly_comp_residual_pool + get_current_bonus_pool bodies
-- are applied via Supabase apply_migration. Full canonical bodies live in
-- pg_proc — regenerate via supabase/schema_snapshots/functions_YYYY-MM-DD.sql
-- per operational_rule 'GitHub mirror pattern for apply_migration'.
