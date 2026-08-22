-- Found via verification, not guessed: prior_year_pl already had an admin-gated
-- SELECT policy (prior_year_pl_admin_select) AND a leftover blanket one
-- (prior_year_pl_read_by_agency, qual = agency_id match only, no role check).
-- Permissive policies OR together, so the blanket one was still winning.
-- My own newly-added prior_year_pl_admin_read is now redundant with the
-- pre-existing prior_year_pl_admin_select — dropping mine, keeping theirs.
DROP POLICY IF EXISTS prior_year_pl_read_by_agency ON public.prior_year_pl;
DROP POLICY IF EXISTS prior_year_pl_admin_read ON public.prior_year_pl;

