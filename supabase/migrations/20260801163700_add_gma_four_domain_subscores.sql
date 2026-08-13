-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 16:37:00 UTC (ledger name: add_gma_four_domain_subscores) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801163700.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS gma_pattern_accuracy integer,
  ADD COLUMN IF NOT EXISTS gma_pattern_speed_seconds integer,
  ADD COLUMN IF NOT EXISTS gma_deductive_accuracy integer,
  ADD COLUMN IF NOT EXISTS gma_deductive_speed_seconds integer,
  ADD COLUMN IF NOT EXISTS gma_numerical_accuracy integer,
  ADD COLUMN IF NOT EXISTS gma_numerical_speed_seconds integer,
  ADD COLUMN IF NOT EXISTS gma_verbal_accuracy integer,
  ADD COLUMN IF NOT EXISTS gma_verbal_speed_seconds integer,
  ADD COLUMN IF NOT EXISTS gma_total_accuracy integer;

COMMENT ON COLUMN public.hiring_candidates.gma_pattern_accuracy IS 'GMA v2 instrument: pattern-matching/matrix-reasoning subtest, count correct.';
COMMENT ON COLUMN public.hiring_candidates.gma_deductive_accuracy IS 'GMA v2 instrument: deductive/rule-application subtest, count correct.';
COMMENT ON COLUMN public.hiring_candidates.gma_numerical_accuracy IS 'GMA v2 instrument: numerical reasoning subtest, count correct.';
COMMENT ON COLUMN public.hiring_candidates.gma_verbal_accuracy IS 'GMA v2 instrument: verbal/reading comprehension subtest, count correct. Distinct from legacy lss_verbal_accuracy (CTS/v1 instruments).';
