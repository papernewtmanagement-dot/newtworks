-- Add optional p_override_lapse to compute_renewal_stack, compute_warning_trigger,
-- compute_seat_projection, compute_seat_projections_for_agency.
-- When NULL (default), behavior unchanged. When provided, that value is used everywhere
-- lapse enters the math: RQM, decay in existing cohorts, decay in future cohorts.
-- Enables 'what if lapse were X%?' scenarios without touching actuals.

CREATE OR REPLACE FUNCTION public.compute_renewal_stack(
  p_team_member_id uuid,
  p_as_of_date date DEFAULT CURRENT_DATE,
  p_override_lapse numeric DEFAULT NULL
)
RETURNS TABLE(annual_renewal_stack numeric, cohort_count integer, diag jsonb)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_agency_id uuid;
  v_pc_rate CONSTANT numeric := 0.08;
  v_lh_rate numeric;
  v_blended_lapse numeric;
BEGIN
  SELECT agency_id INTO v_agency_id FROM public.team WHERE id = p_team_member_id;
  IF v_agency_id IS NULL THEN
    RETURN QUERY SELECT 0::numeric, 0, jsonb_build_object('error','team_member not found');
    RETURN;
  END IF;
  SELECT COALESCE(blended_rate_other, 0.09) INTO v_lh_rate FROM public.agency WHERE id = v_agency_id;
  IF p_override_lapse IS NOT NULL THEN
    v_blended_lapse := p_override_lapse;
  ELSE
    SELECT annualized_rate INTO v_blended_lapse FROM public.compute_lapse_rate(v_agency_id, p_as_of_date) WHERE line = 'blended';
    IF v_blended_lapse IS NULL THEN v_blended_lapse := 0; END IF;
  END IF;
  RETURN QUERY
  WITH cohorts AS (
    SELECT pp.line_of_business, pp.premium_issued,
      make_date(pp.period_year, pp.period_month, 15) AS cohort_date,
      ((p_as_of_date - make_date(pp.period_year, pp.period_month, 15))::numeric / 365.25) AS age_years
    FROM public.producer_production pp
    WHERE pp.team_member_id = p_team_member_id AND pp.premium_issued > 0
      AND COALESCE(pp.premium_type, 'new_business') = 'new_business'
      AND make_date(pp.period_year, pp.period_month, 15) < p_as_of_date
  ),
  eligible AS (SELECT * FROM cohorts WHERE age_years >= 1.0),
  computed AS (
    SELECT SUM(premium_issued *
      CASE WHEN line_of_business IN ('Auto','Fire') THEN v_pc_rate ELSE v_lh_rate END *
      POWER(GREATEST(0.01, 1 - v_blended_lapse), age_years)) AS annual_stack,
      COUNT(*)::int AS n_cohorts FROM eligible
  )
  SELECT COALESCE(c.annual_stack, 0), COALESCE(c.n_cohorts, 0),
    jsonb_build_object('as_of_date', p_as_of_date, 'lapse_used', ROUND(v_blended_lapse, 6),
      'lapse_source', CASE WHEN p_override_lapse IS NOT NULL THEN 'override' ELSE 'compute_lapse_rate' END,
      'pc_rate', v_pc_rate, 'lh_rate', v_lh_rate, 'cohorts_eligible', c.n_cohorts)
  FROM computed c;
END;
$function$;

-- Full compute_warning_trigger, compute_seat_projection, compute_seat_projections_for_agency
-- with p_override_lapse parameter live in migration applied via Supabase MCP.
-- See operational_rule 'Seat profitability attribution' for the complete formula reference.
-- Reference: earlier migrations d5e611d, 49cbe7d, 9431c45, 790ee0d, dbe88af.
