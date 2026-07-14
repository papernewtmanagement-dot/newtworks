-- Financials → Payroll page could not read payroll_runs / payroll_detail: RLS enabled, zero policies.
-- Sibling pattern (comp_recap, journal_entries): SELECT USING (true) for anon+authenticated.
-- Writes stay service-role only (document-processor, manual admin ingest) — no INSERT/UPDATE/DELETE
-- policies added because no frontend surface writes to these tables.

DROP POLICY IF EXISTS anon_read_payroll_runs ON public.payroll_runs;
CREATE POLICY anon_read_payroll_runs
  ON public.payroll_runs
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS anon_read_payroll_detail ON public.payroll_detail;
CREATE POLICY anon_read_payroll_detail
  ON public.payroll_detail
  FOR SELECT
  TO anon, authenticated
  USING (true);
