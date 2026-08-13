-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-12 20:31:05 UTC (ledger name: drop_compute_weekly_comp_v3) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260712203105.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Drop compute_weekly_comp_v3 — its math was folded into compute_weekly_comp_residual_pool
-- as of 2026-07-12 pm rewrite. Verified zero references (SQL + repo code search).
DROP FUNCTION IF EXISTS public.compute_weekly_comp_v3(uuid, date);
