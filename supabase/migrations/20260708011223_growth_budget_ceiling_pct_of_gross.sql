-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 01:12:23 UTC (ledger name: growth_budget_ceiling_pct_of_gross) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708011223.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Switch growth budget ceiling basis: % of TTM gross revenue (dynamic), replacing fixed $ approach
ALTER TABLE public.agency
  ADD COLUMN IF NOT EXISTS growth_budget_ceiling_pct_of_gross NUMERIC;

COMMENT ON COLUMN public.agency.growth_budget_ceiling_pct_of_gross IS
  'Growth budget ceiling as decimal % of trailing 12-month gross revenue. e.g. 0.10 = 10%. Computed $ ceiling = pct × TTM gross via get_growth_budget_ceiling(). Takes precedence over growth_budget_ceiling_annual (which becomes a fixed-$ override, nullable).';

-- Compute function: returns current $ ceiling based on % × TTM gross OR fixed annual override
CREATE OR REPLACE FUNCTION public.get_growth_budget_ceiling(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_pct numeric;
  v_annual_override numeric;
  v_ttm_gross numeric;
  v_ceiling numeric;
  v_basis text;
BEGIN
  SELECT
    growth_budget_ceiling_pct_of_gross,
    growth_budget_ceiling_annual
  INTO v_pct, v_annual_override
  FROM public.agency
  WHERE id = p_agency_id;

  SELECT COALESCE(SUM(total), 0)
  INTO v_ttm_gross
  FROM public.v_pl_rolled_up
  WHERE agency_id = p_agency_id
    AND account_type = 'income'
    AND month_start >= (date_trunc('month', CURRENT_DATE) - INTERVAL '12 months')::date
    AND month_start < date_trunc('month', CURRENT_DATE)::date;

  IF v_pct IS NOT NULL THEN
    v_ceiling := v_pct * v_ttm_gross;
    v_basis := 'pct_of_ttm_gross';
  ELSIF v_annual_override IS NOT NULL THEN
    v_ceiling := v_annual_override;
    v_basis := 'fixed_annual';
  ELSE
    v_ceiling := NULL;
    v_basis := 'none';
  END IF;

  RETURN jsonb_build_object(
    'ceiling_annual', ROUND(v_ceiling, 2),
    'pct_of_ttm_gross', v_pct,
    'ttm_gross', ROUND(v_ttm_gross, 2),
    'ttm_window_start', (date_trunc('month', CURRENT_DATE) - INTERVAL '12 months')::date,
    'ttm_window_end', (date_trunc('month', CURRENT_DATE) - INTERVAL '1 day')::date,
    'basis', v_basis,
    'computed_at', now()
  );
END;
$function$;
