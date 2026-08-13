-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-22 20:19:45 UTC (ledger name: hiring_candidates_add_lss_exceptions_confirmed_col) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260722201945.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS lss_exceptions_confirmed jsonb NOT NULL DEFAULT '[]'::jsonb;
