-- prior_year_pl had SELECT policies but only for authenticated role. The Financials
-- module runs on the anon key (no auth check), so get_pnl_history_for_entity /
-- get_pnl_history_own_only were returning zero historical rows when called via
-- the frontend even though they returned 4000+ rows when called by service_role.
-- Adds the standard anon,authenticated read pattern matching every other
-- Financials-adjacent table.

CREATE POLICY "anon_read_prior_year_pl"
ON public.prior_year_pl
FOR SELECT
TO anon, authenticated
USING (true);
