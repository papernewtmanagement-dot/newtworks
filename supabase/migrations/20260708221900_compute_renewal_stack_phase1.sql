-- compute_renewal_stack(team_member_id, as_of_date)
-- Phase 1 of warning-trigger renewal-stack wiring.
-- Per-cohort formula: annual_contribution = premium × rate[LOB] × (1 - blended_lapse)^years_since_issue
-- Gate: only cohorts >= 12 months old contribute (year-1 is still new_business territory).
-- Rates: Auto/Fire = 0.08 (SMVC-stripped P&C base, matches warning_trigger).
--        Life/Health = agency.blended_rate_other (default 0.09 if null).
-- Blended lapse pulled from compute_lapse_rate(agency_id, as_of_date) 'blended' row.

CREATE OR REPLACE FUNCTION public.compute_renewal_stack(
  p_team_member_id uuid,
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE(
  team_member_id uuid,
  as_of_date date,
  blended_lapse_annual numeric,
  cohort_count integer,
  eligible_cohort_count integer,
  annual_renewal_stack numeric,
  breakdown_by_lob jsonb,
  cohorts jsonb
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agency_id  uuid;
  v_pc_rate    CONSTANT numeric := 0.08;
  v_lh_rate    numeric;
  v_lapse      numeric;
BEGIN
  SELECT t.agency_id, a.blended_rate_other
  INTO v_agency_id, v_lh_rate
  FROM public.team t
  JOIN public.agency a ON a.id = t.agency_id
  WHERE t.id = p_team_member_id;

  IF v_agency_id IS NULL THEN
    RETURN;
  END IF;

  IF v_lh_rate IS NULL THEN
    v_lh_rate := 0.09;
  END IF;

  SELECT annualized_rate
  INTO v_lapse
  FROM public.compute_lapse_rate(v_agency_id, p_as_of_date)
  WHERE line = 'blended';

  IF v_lapse IS NULL OR v_lapse <= 0 THEN
    v_lapse := 0.10;
  END IF;

  RETURN QUERY
  WITH cohorts AS (
    SELECT
      pp.period_year,
      pp.period_month,
      pp.line_of_business,
      pp.premium_issued,
      make_date(pp.period_year, pp.period_month, 15) AS cohort_mid,
      (p_as_of_date - make_date(pp.period_year, pp.period_month, 15))::numeric / 365.25 AS years_since_issue,
      CASE
        WHEN pp.line_of_business IN ('Auto','Fire') THEN v_pc_rate
        ELSE v_lh_rate
      END AS lob_rate
    FROM public.producer_production pp
    WHERE pp.team_member_id = p_team_member_id
      AND pp.premium_issued > 0
      AND COALESCE(pp.premium_type, 'new_business') = 'new_business'
      AND make_date(pp.period_year, pp.period_month, 15) < p_as_of_date
  ),
  eligible AS (
    SELECT
      c.*,
      c.premium_issued * c.lob_rate * POWER(1 - v_lapse, c.years_since_issue) AS annual_contribution
    FROM cohorts c
    WHERE c.years_since_issue >= 1.0
  ),
  by_lob AS (
    SELECT
      e.line_of_business,
      COUNT(*)::int AS cohort_count,
      SUM(e.premium_issued) AS total_premium_seed,
      SUM(e.annual_contribution) AS annual_contribution
    FROM eligible e
    GROUP BY e.line_of_business
  )
  SELECT
    p_team_member_id,
    p_as_of_date,
    ROUND(v_lapse, 6),
    (SELECT COUNT(*)::int FROM cohorts),
    (SELECT COUNT(*)::int FROM eligible),
    ROUND(COALESCE((SELECT SUM(annual_contribution) FROM eligible), 0), 2),
    COALESCE(
      (SELECT jsonb_object_agg(bl.line_of_business, jsonb_build_object(
        'cohort_count', bl.cohort_count,
        'total_premium_seed', ROUND(bl.total_premium_seed, 2),
        'annual_contribution', ROUND(bl.annual_contribution, 2)
      )) FROM by_lob bl),
      '{}'::jsonb
    ),
    COALESCE(
      (SELECT jsonb_agg(jsonb_build_object(
        'period', e.period_year || '-' || LPAD(e.period_month::text, 2, '0'),
        'lob', e.line_of_business,
        'premium_issued', ROUND(e.premium_issued, 2),
        'years_since_issue', ROUND(e.years_since_issue, 3),
        'lob_rate', e.lob_rate,
        'lapse_survival_factor', ROUND(POWER(1 - v_lapse, e.years_since_issue), 4),
        'annual_contribution', ROUND(e.annual_contribution, 2)
      ) ORDER BY e.period_year, e.period_month, e.line_of_business)
      FROM eligible e),
      '[]'::jsonb
    );
END;
$$;

COMMENT ON FUNCTION public.compute_renewal_stack(uuid, date) IS
'Computes annualized renewal-commission stack for a team member from their producer_production cohorts. '
'Per-cohort: premium × rate[LOB] × (1 - blended_lapse)^years_since_issue. '
'Gate: cohorts ≥12 months old only. P&C rate = 0.08 (SMVC-stripped); L&H rate = agency.blended_rate_other. '
'Blended lapse from compute_lapse_rate(agency,as_of).blended row.';
