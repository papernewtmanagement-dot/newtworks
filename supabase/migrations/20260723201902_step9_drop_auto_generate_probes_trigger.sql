-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-23 20:19:02 UTC (ledger name: step9_drop_auto_generate_probes_trigger) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260723201902.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Step 9 of HireGauge function architecture refactor
-- ==========================================================================
-- Purpose: drop the auto-fire trigger + orphaned trigger function.
-- Motivation:
--   (1) The trigger function references `NEW.is_team_member`, a column being
--       retired in Step 10. Keeping the function alive after Step 10 would
--       cause every INSERT/UPDATE on hiring_candidates to error.
--   (2) Peter opted for manual probe generation via the UI button rather than
--       auto-fire. The `generateCustomProbes` callback in CandidateDetail.jsx
--       remains wired to the edge fn, so the manual path is intact.
--
-- After this migration:
--   - Trigger `trg_auto_generate_probes_on_cts` is gone from hiring_candidates
--   - Function `auto_generate_probes_on_cts_populated()` is gone
--   - Edge function `generate-custom-probes` stays; only the auto-fire path is
--     removed.
-- ==========================================================================

DROP TRIGGER IF EXISTS trg_auto_generate_probes_on_cts ON public.hiring_candidates;
DROP FUNCTION IF EXISTS public.auto_generate_probes_on_cts_populated();
