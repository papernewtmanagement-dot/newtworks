-- v_income_statement UNIONs journal data with prior_year_pl (pre-cutover P&L
-- import). Missed on the first pass. Same treatment as journal_entries/
-- journal_lines/chart_of_accounts -- no team-visible module reads it directly,
-- it only reaches staff through the income statement view.
DROP POLICY IF EXISTS anon_read_prior_year_pl ON public.prior_year_pl;
CREATE POLICY prior_year_pl_admin_read ON public.prior_year_pl FOR SELECT TO authenticated USING (is_agency_admin());
