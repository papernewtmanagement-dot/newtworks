-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 01:27:03 UTC (ledger name: payroll_runs_unique_pay_period_end) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708012703.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- Prevent duplicate payroll_runs rows for the same pay period (from any processor).
-- With this in place, the doc-processor filename-fallback that ALSO matches "Payroll Summary.pdf"
-- will error out on insert (graceful — its document row will be marked as failed) but no data corruption.
CREATE UNIQUE INDEX IF NOT EXISTS ux_payroll_runs_agency_period
  ON public.payroll_runs (agency_id, pay_period_end)
  WHERE agency_id IS NOT NULL AND pay_period_end IS NOT NULL;

COMMENT ON INDEX ux_payroll_runs_agency_period IS
  'Race-safety: prevents duplicate payroll_runs from doc-processor and payroll-email-parser both ingesting the same email. First writer wins; second gets constraint violation. See operational_rule "SurePayroll PDF parser (v8)".';
