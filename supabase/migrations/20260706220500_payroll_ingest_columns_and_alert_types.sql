-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 22:05:00 UTC (ledger name: payroll_ingest_columns_and_alert_types) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706220500.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Add idempotency + audit columns to payroll_runs
ALTER TABLE public.payroll_runs
  ADD COLUMN IF NOT EXISTS gmail_message_id text,
  ADD COLUMN IF NOT EXISTS gmail_thread_id text,
  ADD COLUMN IF NOT EXISTS raw_pdf_text text,
  ADD COLUMN IF NOT EXISTS transmit_date date,
  ADD COLUMN IF NOT EXISTS total_employee_taxes numeric,
  ADD COLUMN IF NOT EXISTS total_employer_taxes numeric,
  ADD COLUMN IF NOT EXISTS total_employee_deductions numeric,
  ADD COLUMN IF NOT EXISTS total_cash_requirement numeric,
  ADD COLUMN IF NOT EXISTS parsed_at timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS idx_payroll_runs_gmail_msg
  ON public.payroll_runs (gmail_message_id)
  WHERE gmail_message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_payroll_runs_period
  ON public.payroll_runs (agency_id, business_entity_id, pay_period_start, pay_period_end);

-- Add YTD gross column to payroll_detail so parser can preserve the PDF's YTD directly
ALTER TABLE public.payroll_detail
  ADD COLUMN IF NOT EXISTS ytd_gross numeric,
  ADD COLUMN IF NOT EXISTS employer_taxes numeric,
  ADD COLUMN IF NOT EXISTS raw_earnings jsonb,
  ADD COLUMN IF NOT EXISTS raw_deductions jsonb,
  ADD COLUMN IF NOT EXISTS raw_employer_taxes jsonb;

CREATE UNIQUE INDEX IF NOT EXISTS idx_payroll_detail_run_person
  ON public.payroll_detail (payroll_run_id, team_member_id);
