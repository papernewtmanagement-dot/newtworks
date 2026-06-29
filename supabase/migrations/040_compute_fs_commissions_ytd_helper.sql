-- Migration 040: SMVC FS Commissions bucket source helper.
-- Returns Life new + Life renewal commission $ YTD from comp_recap.
-- Health excluded per operational_rule "Health out of compensation-tracking scope".
-- Pacific Life VUL flows through life_new/life_renewal in comp_recap.
--
-- Replaces life_paid_for_premium_ytd as the SMVC FS bucket input. Premium was
-- wrong unit; SMVC FS Commissions bucket spec is COMMISSIONS, not premium.

CREATE OR REPLACE FUNCTION public.compute_fs_commissions_ytd(
  p_agency_id uuid,
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_year  int := EXTRACT(YEAR  FROM p_as_of_date)::int;
  v_month int := EXTRACT(MONTH FROM p_as_of_date)::int;
  v_total numeric;
BEGIN
  SELECT COALESCE(SUM(amount), 0)
  INTO v_total
  FROM public.comp_recap
  WHERE agency_id     = p_agency_id
    AND period_year   = v_year
    AND period_month <= v_month
    AND comp_category IN ('life_new', 'life_renewal');

  RETURN v_total;
END;
$fn$;

COMMENT ON FUNCTION public.compute_fs_commissions_ytd(uuid, date) IS
  'SMVC FS Commissions bucket YTD = SUM(comp_recap.amount) for life_new + life_renewal through as_of month. Health excluded by standing operational rule.';

GRANT EXECUTE ON FUNCTION public.compute_fs_commissions_ytd(uuid, date) TO anon, authenticated, service_role;
