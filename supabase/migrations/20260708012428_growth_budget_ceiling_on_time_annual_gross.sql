-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 01:24:28 UTC (ledger name: growth_budget_ceiling_on_time_annual_gross) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708012428.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Rewrite get_growth_budget_ceiling to use on-time annualized YTD gross ex-scorecard
CREATE OR REPLACE FUNCTION public.get_growth_budget_ceiling(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_pct numeric;
  v_annual_override numeric;
  v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int;
  v_max_period_month int;
  v_comp_anchor_date date;
  v_days_elapsed int;
  v_annualization numeric;
  v_ytd_gross_ex_scorecard numeric;
  v_on_time_annual_gross numeric;
  v_scorecard_ytd numeric;
  v_ceiling numeric;
  v_basis text;
BEGIN
  SELECT
    growth_budget_ceiling_pct_of_gross,
    growth_budget_ceiling_annual
  INTO v_pct, v_annual_override
  FROM public.agency
  WHERE id = p_agency_id;

  -- Anchor annualization on end of latest complete comp_recap period
  SELECT MAX(period_month) INTO v_max_period_month
  FROM public.comp_recap
  WHERE agency_id = p_agency_id AND period_year = v_year;

  IF v_max_period_month IS NULL THEN
    -- No comp data yet this year — fall back to override or NULL
    v_on_time_annual_gross := 0;
    v_ytd_gross_ex_scorecard := 0;
    v_scorecard_ytd := 0;
    v_annualization := NULL;
    v_days_elapsed := NULL;
    v_comp_anchor_date := NULL;
  ELSE
    v_comp_anchor_date := (make_date(v_year, v_max_period_month, 1) + INTERVAL '1 month - 1 day')::date;
    v_days_elapsed := (v_comp_anchor_date - make_date(v_year, 1, 1))::int + 1;
    v_annualization := 365.0 / v_days_elapsed::numeric;

    -- YTD gross earnings excluding scorecard bonus + deductions
    SELECT COALESCE(SUM(amount), 0)
    INTO v_ytd_gross_ex_scorecard
    FROM public.comp_recap
    WHERE agency_id = p_agency_id
      AND period_year = v_year
      AND comp_category NOT LIKE 'deduction_%'
      AND NOT (comp_category = 'state_farm_bonuses' AND description ILIKE '%scorecard%');

    -- Scorecard YTD (for reporting only)
    SELECT COALESCE(SUM(amount), 0)
    INTO v_scorecard_ytd
    FROM public.comp_recap
    WHERE agency_id = p_agency_id
      AND period_year = v_year
      AND comp_category = 'state_farm_bonuses'
      AND description ILIKE '%scorecard%';

    v_on_time_annual_gross := v_ytd_gross_ex_scorecard * v_annualization;
  END IF;

  IF v_pct IS NOT NULL AND v_on_time_annual_gross > 0 THEN
    v_ceiling := v_pct * v_on_time_annual_gross;
    v_basis := 'pct_of_on_time_annual_gross_ex_scorecard';
  ELSIF v_annual_override IS NOT NULL THEN
    v_ceiling := v_annual_override;
    v_basis := 'fixed_annual_override';
  ELSE
    v_ceiling := NULL;
    v_basis := 'none';
  END IF;

  RETURN jsonb_build_object(
    'ceiling_annual', ROUND(v_ceiling, 2),
    'pct_of_on_time_annual_gross', v_pct,
    'ytd_gross_ex_scorecard', ROUND(v_ytd_gross_ex_scorecard, 2),
    'on_time_annual_gross', ROUND(v_on_time_annual_gross, 2),
    'scorecard_ytd_excluded', ROUND(v_scorecard_ytd, 2),
    'annualization_factor', ROUND(v_annualization, 5),
    'days_elapsed', v_days_elapsed,
    'comp_anchor_date', v_comp_anchor_date,
    'max_period_month', v_max_period_month,
    'basis', v_basis,
    'computed_at', now()
  );
END;
$function$;

COMMENT ON COLUMN public.agency.growth_budget_ceiling_pct_of_gross IS
  'Growth budget ceiling as decimal % of on-time annualized YTD gross revenue excluding Scorecard bonus. e.g. 0.10 = 10%. Basis: SUM(comp_recap earning entries YTD, excluding SCORECARD BONUS description, excluding deduction_* categories) × (365 / days_elapsed_thru_latest_complete_period_month). Compute via get_growth_budget_ceiling(agency_id) RPC.';
