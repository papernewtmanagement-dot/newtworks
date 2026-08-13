-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 20:01:43 UTC (ledger name: tier3_comp_engine_parity_baseline_cleanup) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708200143.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Comp engine parity verified byte-exact across all 3 refactors (compute_pool_carveouts,
-- compute_weekly_comp_residual_pool, compose_weekly_cpr_html). Drop ephemeral baseline table.
DROP TABLE IF EXISTS public._tier3_comp_parity;

-- Final function count check
SELECT COUNT(*) AS total_public_fns
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind = 'f';
