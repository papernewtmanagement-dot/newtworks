-- Historical Sales Points per team member per quarter, derived live from producer_production
-- via current compute_person_commissions_quarterly (1 SP = $1 team commission).
-- No stored SP snapshots — plan changes reflect immediately on rerun.
CREATE OR REPLACE VIEW public.v_team_sales_points_quarterly AS
WITH periods AS (
  SELECT DISTINCT
    pp.agency_id,
    pp.team_member_id,
    pp.period_year,
    ((pp.period_month - 1) / 3 + 1)::int AS quarter_num
  FROM public.producer_production pp
)
SELECT
  p.agency_id,
  p.team_member_id,
  p.period_year,
  p.quarter_num,
  make_date(p.period_year, (p.quarter_num - 1) * 3 + 1, 1) AS period_start,
  (make_date(p.period_year, (p.quarter_num - 1) * 3 + 1, 1) + interval '3 months' - interval '1 day')::date AS period_end,
  (r->'issued'->>'auto_apps')::int AS auto_apps,
  (r->'issued'->>'fire_apps')::int AS fire_apps,
  (r->'issued'->>'auto_premium')::numeric AS auto_premium,
  (r->'issued'->>'fire_premium')::numeric AS fire_premium,
  (r->'issued'->>'life_premium')::numeric AS life_premium,
  (r->'issued'->>'health_premium')::numeric AS health_premium,
  (r->'rates'->>'pc_rate_capped')::numeric AS pc_rate_capped,
  (r->'rates'->>'lh_rate_capped')::numeric AS lh_rate_capped,
  ROUND((r->'commission'->>'pc_commission')::numeric, 2) AS pc_commission,
  ROUND((r->'commission'->>'lh_commission')::numeric, 2) AS lh_commission,
  ROUND((r->'commission'->>'total_commission')::numeric, 2) AS sales_points,
  r->>'plan_version' AS plan_version,
  (r->>'sf_config_synced')::date AS sf_config_synced
FROM periods p
CROSS JOIN LATERAL public.compute_person_commissions_quarterly(
  p.agency_id, p.team_member_id, p.period_year, p.quarter_num
) AS r
WHERE (r->'issued'->>'auto_premium')::numeric > 0
   OR (r->'issued'->>'fire_premium')::numeric > 0
   OR (r->'issued'->>'life_premium')::numeric > 0
   OR (r->'issued'->>'health_premium')::numeric > 0;

COMMENT ON VIEW public.v_team_sales_points_quarterly IS
  'Historical Sales Points by team member × quarter, derived live from producer_production via compute_person_commissions_quarterly. 1 SP = $1 team commission. Rerun reflects current plan_version — no stored snapshots (compensation_data_freshness principle).';

-- Renewal stack: annual renewal-commission income currently attributable to a team member's historical book
-- Formula: Σ over cohorts ≥12mo old, premium_issued × renewal_rate[LOB] × (1 − lapse_rate[LOB])^years_since_issue
CREATE OR REPLACE FUNCTION public.compute_renewal_stack(
  p_agency_id uuid,
  p_team_member_id uuid,
  p_as_of_date date DEFAULT CURRENT_DATE,
  p_lapse_override numeric DEFAULT NULL,
  p_life_renewal_rate numeric DEFAULT 0.05,
  p_health_renewal_rate numeric DEFAULT 0.05
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pc_renewal_rate numeric;
  v_auto_lapse numeric;
  v_fire_lapse numeric;
  v_life_lapse numeric;
  v_blended_lapse numeric;
  v_auto_stack numeric := 0;
  v_fire_stack numeric := 0;
  v_life_stack numeric := 0;
  v_health_stack numeric := 0;
  v_cohorts jsonb;
BEGIN
  SELECT pc_base_rate INTO v_pc_renewal_rate
  FROM public.agency WHERE id = p_agency_id;

  IF p_lapse_override IS NOT NULL THEN
    v_auto_lapse := p_lapse_override;
    v_fire_lapse := p_lapse_override;
    v_life_lapse := p_lapse_override;
    v_blended_lapse := p_lapse_override;
  ELSE
    SELECT MAX(CASE WHEN line='auto' THEN annualized_rate END),
           MAX(CASE WHEN line='fire' THEN annualized_rate END),
           MAX(CASE WHEN line='life' THEN annualized_rate END),
           MAX(CASE WHEN line='blended' THEN annualized_rate END)
      INTO v_auto_lapse, v_fire_lapse, v_life_lapse, v_blended_lapse
      FROM public.compute_lapse_rate(p_agency_id, p_as_of_date);
  END IF;

  WITH cohort_detail AS (
    SELECT
      pp.line_of_business,
      pp.period_year,
      pp.period_month,
      make_date(pp.period_year, pp.period_month, 1) AS issue_date,
      SUM(pp.premium_issued) AS premium,
      (p_as_of_date - make_date(pp.period_year, pp.period_month, 1))::numeric / 365.0 AS years_since_issue
    FROM public.producer_production pp
    WHERE pp.agency_id = p_agency_id
      AND pp.team_member_id = p_team_member_id
      AND make_date(pp.period_year, pp.period_month, 1) <= (p_as_of_date - interval '12 months')::date
    GROUP BY pp.line_of_business, pp.period_year, pp.period_month
  ),
  by_lob AS (
    SELECT
      SUM(CASE WHEN line_of_business='Auto' THEN premium * v_pc_renewal_rate * GREATEST(0, POWER(1 - v_auto_lapse, years_since_issue)) END) AS auto_stack,
      SUM(CASE WHEN line_of_business='Fire' THEN premium * v_pc_renewal_rate * GREATEST(0, POWER(1 - v_fire_lapse, years_since_issue)) END) AS fire_stack,
      SUM(CASE WHEN line_of_business='Life' THEN premium * p_life_renewal_rate * GREATEST(0, POWER(1 - v_life_lapse, years_since_issue)) END) AS life_stack,
      SUM(CASE WHEN line_of_business='Health' THEN premium * p_health_renewal_rate * GREATEST(0, POWER(1 - COALESCE(v_life_lapse, v_blended_lapse), years_since_issue)) END) AS health_stack
    FROM cohort_detail
  ),
  cohort_array AS (
    SELECT jsonb_agg(
      jsonb_build_object(
        'lob', line_of_business,
        'issue_year', period_year,
        'issue_month', period_month,
        'premium', ROUND(premium, 2),
        'years_since_issue', ROUND(years_since_issue, 3),
        'lapse_used', ROUND(CASE
          WHEN line_of_business='Auto' THEN v_auto_lapse
          WHEN line_of_business='Fire' THEN v_fire_lapse
          WHEN line_of_business IN ('Life','Health') THEN COALESCE(v_life_lapse, v_blended_lapse)
        END, 4),
        'decay', ROUND(GREATEST(0, POWER(1 - CASE
          WHEN line_of_business='Auto' THEN v_auto_lapse
          WHEN line_of_business='Fire' THEN v_fire_lapse
          WHEN line_of_business IN ('Life','Health') THEN COALESCE(v_life_lapse, v_blended_lapse)
        END, years_since_issue)), 4),
        'annual_renewal_income', ROUND(premium * CASE
          WHEN line_of_business IN ('Auto','Fire') THEN v_pc_renewal_rate
          WHEN line_of_business='Life' THEN p_life_renewal_rate
          WHEN line_of_business='Health' THEN p_health_renewal_rate
        END * GREATEST(0, POWER(1 - CASE
          WHEN line_of_business='Auto' THEN v_auto_lapse
          WHEN line_of_business='Fire' THEN v_fire_lapse
          WHEN line_of_business IN ('Life','Health') THEN COALESCE(v_life_lapse, v_blended_lapse)
        END, years_since_issue)), 2)
      ) ORDER BY period_year, period_month, line_of_business
    ) AS arr
    FROM cohort_detail
  )
  SELECT auto_stack, fire_stack, life_stack, health_stack, COALESCE(ca.arr, '[]'::jsonb)
    INTO v_auto_stack, v_fire_stack, v_life_stack, v_health_stack, v_cohorts
    FROM by_lob, cohort_array ca;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'team_member_id', p_team_member_id,
    'as_of_date', p_as_of_date,
    'assumptions', jsonb_build_object(
      'pc_renewal_rate', v_pc_renewal_rate,
      'life_renewal_rate', p_life_renewal_rate,
      'health_renewal_rate', p_health_renewal_rate,
      'auto_lapse_annualized', v_auto_lapse,
      'fire_lapse_annualized', v_fire_lapse,
      'life_lapse_annualized', v_life_lapse,
      'blended_lapse_annualized', v_blended_lapse,
      'lapse_override', p_lapse_override,
      'cohort_gate', '>=12 months since issue'
    ),
    'stack_by_lob', jsonb_build_object(
      'auto_annual', ROUND(COALESCE(v_auto_stack, 0), 2),
      'fire_annual', ROUND(COALESCE(v_fire_stack, 0), 2),
      'life_annual', ROUND(COALESCE(v_life_stack, 0), 2),
      'health_annual', ROUND(COALESCE(v_health_stack, 0), 2)
    ),
    'total_annual_renewal_income', ROUND(COALESCE(v_auto_stack,0)+COALESCE(v_fire_stack,0)+COALESCE(v_life_stack,0)+COALESCE(v_health_stack,0), 2),
    'cohorts', v_cohorts,
    'computed_at', NOW()
  );
END;
$$;

COMMENT ON FUNCTION public.compute_renewal_stack IS
  'Annual renewal-commission income currently attributable to a team member''s historical book. Sums over cohorts >=12 months old, applies renewal rate × (1 - lapse)^years_since_issue. Life + Health renewal rates default 0.05 (SF typical). p_lapse_override lets caller pass blended benchmark (e.g. 0.11) to compare against corp benchmark vs live lapse.';
