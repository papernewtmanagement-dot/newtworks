-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-23 22:20:08 UTC (ledger name: step11_drop_orphaned_cts_and_verdict_functions) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260723222008.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Step 11 of HireGauge function architecture refactor
-- ==========================================================================
-- Drop the 8 orphaned functions. All have zero callers verified at commit
-- time (function bodies + view definitions swept). Signatures below match
-- pg_get_function_identity_arguments output as of 2026-07-23.
--
-- Prior steps ensured this is safe:
--   Step 8: hiregauge_evaluate_candidate rewritten to remove leadership_style.
--   Step 9: auto_generate_probes_on_cts_populated trigger + fn dropped.
--   Step 10 prep: assessment_drivers + assessment_nurture cell fns rewritten
--                 to do the math directly; v_hiring_candidates rewired to
--                 call cells (not raw cts_* fns).
--   Step 10: v_hiring_candidates + 5 columns + 2 three_construct_verdict fns
--            dropped. Column drops cascaded generation-expression drops of
--            cts_ego_drive / cts_empathy / cts_leadership_style callers.
-- ==========================================================================

DROP FUNCTION IF EXISTS public.cts_ego_drive(integer, integer, integer, integer, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS public.cts_empathy(integer, integer, integer, integer, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS public.cts_leadership_style(integer, integer);
DROP FUNCTION IF EXISTS public.cts_profile_validity(uuid);
DROP FUNCTION IF EXISTS public.cts_timing_assessment(uuid);
DROP FUNCTION IF EXISTS public.cts_assessment_drivers(integer, integer, integer);
DROP FUNCTION IF EXISTS public.cts_assessment_nurture(text, text, integer, integer);
DROP FUNCTION IF EXISTS public.cts_drivers_assessment_cell(uuid, text);
