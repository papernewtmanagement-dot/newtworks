-- business_entities had RLS enabled but zero policies → anon role saw 0 rows.
-- This broke: (a) Financials breadcrumb (empty allEntities → no ancestor walk),
-- (b) subsidiary rollup (P&L RPCs are SECURITY INVOKER and hit RLS on their
-- internal joins when called by anon), (c) Overview KPIs (fullRows empty),
-- and any other reader depending on business_entities via anon.
-- Matches the anon_read_<table> pattern already in place on chart_of_accounts,
-- journal_entries, journal_lines, payroll_runs, payroll_detail, team, etc.

CREATE POLICY "anon_read_business_entities"
ON public.business_entities
FOR SELECT
TO anon, authenticated
USING (true);
