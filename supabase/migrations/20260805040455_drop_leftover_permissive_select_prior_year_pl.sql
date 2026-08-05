-- Found via verification, not guessed: prior_year_pl already had an admin-gated
-- SELECT policy (prior_year_pl_admin_select) AND a leftover blanket one
-- (prior_year_pl_read_by_agency, qual = agency_id match only, no role check).
-- Permissive policies OR together, so the blanket one was still winning.
-- The newly-added prior_year_pl_admin_read (mig_03) is redundant with the
-- pre-existing prior_year_pl_admin_select -- dropping the new one, keeping
-- the pre-existing one.
DROP POLICY IF EXISTS prior_year_pl_read_by_agency ON public.prior_year_pl;
DROP POLICY IF EXISTS prior_year_pl_admin_read ON public.prior_year_pl;
