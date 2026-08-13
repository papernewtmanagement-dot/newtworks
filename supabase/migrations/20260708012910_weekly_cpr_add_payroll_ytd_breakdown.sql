-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 01:29:10 UTC (ledger name: weekly_cpr_add_payroll_ytd_breakdown) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708012910.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS payroll_ytd_breakdown jsonb;

COMMENT ON COLUMN public.weekly_cpr_team_detail.payroll_ytd_breakdown IS
  'Per-item YTD breakdown of the paycheck that produced payroll_ytd_paid. Structure: { items: {LABEL: {period, ytd, hours?}}, period_total, ytd_total, period_hours }. Populated by payroll-email-parser during CPR update. Enables CPR UI to show PTO YTD, LIFE * YTD, etc. without joining back to payroll_detail.';
