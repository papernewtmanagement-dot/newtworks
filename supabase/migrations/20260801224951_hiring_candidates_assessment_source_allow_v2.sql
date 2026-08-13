-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 22:49:51 UTC (ledger name: hiring_candidates_assessment_source_allow_v2) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801224951.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT hiring_candidates_assessment_source_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_assessment_source_check
  CHECK ((assessment_source = ANY (ARRAY['v1'::text, 'v2'::text, 'cts'::text])) OR (assessment_source IS NULL));
