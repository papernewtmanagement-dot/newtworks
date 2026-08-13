-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 03:41:30 UTC (ledger name: legacy_source_removal_04_drop_legacy_staging_fn) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706034130.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Migration 1 dropped without-args signature; actual sig is (uuid, integer, integer).
DROP FUNCTION IF EXISTS public.legacy_post_staged_batch(uuid, integer, integer);
