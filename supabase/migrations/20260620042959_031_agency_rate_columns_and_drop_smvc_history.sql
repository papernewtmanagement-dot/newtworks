-- Migration 031: Move SMVC rate metadata onto agency table, create v_agency_rates view, drop smvc_history
-- Locked with Peter 2026-06-20

-- 1. New agency columns
ALTER TABLE public.agency
  ADD COLUMN IF NOT EXISTS pc_base_rate numeric,
  ADD COLUMN IF NOT EXISTS smvc_rate_pc_prior_year numeric,
  ADD COLUMN IF NOT EXISTS smvc_rate_pc_2_years_prior numeric;

COMMENT ON COLUMN public.agency.pc_base_rate IS 'Current-year P&C base commission rate as decimal (e.g., 0.08 = 8% under AA05). Contract constant for the year; changes at AA28 transition (1/1/2028).';
COMMENT ON COLUMN public.agency.smvc_rate_pc IS 'Currently-applied SMVC rate as decimal (e.g., 0.0241 = 2.41%). Locked by Better Of from prior years.';
COMMENT ON COLUMN public.agency.smvc_rate_pc_prior_year IS 'Calculated SMVC rate for prior measurement year (decimal). Input to Better Of rolling average.';
COMMENT ON COLUMN public.agency.smvc_rate_pc_2_years_prior IS 'Calculated SMVC rate for 2 years prior measurement year (decimal). Input to Better Of rolling average.';

-- 2. Populate values for Story Agency
-- Sources:
--   pc_base_rate: smvc_history.base_rate (0.08)
--   smvc_rate_pc_prior_year: 2025 calculated = 2.37% (from persistent_memory "SMVC Calculated and Applied rates")
--   smvc_rate_pc_2_years_prior: 2024 calculated = 2.25%
UPDATE public.agency
SET
  pc_base_rate              = 0.0800,
  smvc_rate_pc_prior_year   = 0.0237,
  smvc_rate_pc_2_years_prior = 0.0225
WHERE id = '126794dd-25ff-47d2-a436-724499733365';

-- 3. v_agency_rates view (computes effective_pc_rate at runtime — no stored sum)
CREATE OR REPLACE VIEW public.v_agency_rates AS
SELECT
  id,
  name,
  pc_base_rate,
  smvc_rate_pc,
  (pc_base_rate + smvc_rate_pc) AS effective_pc_rate,
  smvc_rate_pc_prior_year,
  smvc_rate_pc_2_years_prior,
  blended_rate_other,
  lapse_rate_annual,
  aipp_rate,
  payroll_burden_multiplier,
  rates_are_defaults
FROM public.agency;

COMMENT ON VIEW public.v_agency_rates IS 'Convenience view of agency rates including computed effective_pc_rate = pc_base_rate + smvc_rate_pc. Read via this view; never store the computed sum on a table.';

-- 4. Rewrite compute_on_time_smvc_with_better_of to read priors from agency
CREATE OR REPLACE FUNCTION public.compute_on_time_smvc_with_better_of(
  p_agency_id uuid, p_program_year integer, p_pc_production_actual numeric,
  p_auto_pif_gain numeric, p_fire_pif_gain numeric,
  p_fs_credits numeric, p_ips_activity numeric
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_current jsonb;
  v_current_rate numeric;
  v_prior1 numeric;
  v_prior2 numeric;
  v_priors_used int := 0;
  v_avg_rate numeric;
  v_better_of_rate numeric;
  v_better_of_source text;
BEGIN
  v_current := public.compute_on_time_smvc(p_agency_id, p_program_year, p_pc_production_actual, p_auto_pif_gain, p_fire_pif_gain, p_fs_credits, p_ips_activity);
  v_current_rate := (v_current->>'capped_smvc_decimal')::numeric;

  -- Pull prior-year SMVC values from agency table (replaces smvc_history reads)
  SELECT smvc_rate_pc_prior_year, smvc_rate_pc_2_years_prior
  INTO v_prior1, v_prior2
  FROM public.agency
  WHERE id = p_agency_id;

  v_priors_used := (CASE WHEN v_prior1 IS NOT NULL THEN 1 ELSE 0 END)
                 + (CASE WHEN v_prior2 IS NOT NULL THEN 1 ELSE 0 END);

  IF v_priors_used >= 2 THEN
    v_avg_rate := (v_current_rate + v_prior1 + v_prior2) / 3.0;
  ELSIF v_priors_used = 1 THEN
    v_avg_rate := (v_current_rate + COALESCE(v_prior1, v_prior2)) / 2.0;
  ELSE
    v_avg_rate := v_current_rate;
  END IF;

  IF v_current_rate >= v_avg_rate THEN
    v_better_of_rate := LEAST(0.03, v_current_rate);
    v_better_of_source := 'current_year';
  ELSE
    v_better_of_rate := LEAST(0.03, v_avg_rate);
    v_better_of_source := 'rolling_average';
  END IF;

  RETURN v_current || jsonb_build_object(
    'prior_year_smvc',     v_prior1,
    'prior_2_year_smvc',   v_prior2,
    'priors_used_in_avg',  v_priors_used,
    'rolling_avg_smvc',    v_avg_rate,
    'applied_smvc_decimal', v_better_of_rate,
    'better_of_source',    v_better_of_source
  );
END;
$function$;

-- 5. Drop smvc_history
DROP TABLE public.smvc_history;
