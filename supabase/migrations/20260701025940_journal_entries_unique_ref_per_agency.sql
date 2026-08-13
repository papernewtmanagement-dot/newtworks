-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-01 02:59:40 UTC (ledger name: journal_entries_unique_ref_per_agency) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260701025940.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Enforces true idempotency for doc-processor postings.
-- Rows with reference_number IS NULL (older manual legacy-source cutover entries) are
-- exempt via the partial index — Postgres treats NULLs as always distinct.
-- Uses partial unique index rather than a table constraint so NULLs stay ignored.
CREATE UNIQUE INDEX IF NOT EXISTS journal_entries_agency_reference_unique
  ON public.journal_entries (agency_id, reference_number)
  WHERE reference_number IS NOT NULL;
