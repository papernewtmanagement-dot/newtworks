-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-10 23:25:20 UTC (ledger name: drop_unused_hiring_tables_superseded_by_team_assessments) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260710232520.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- All three empty; superseded by team_assessments hiring workflow columns.
-- CASCADE handles the interviews.applicant_id + offers.applicant_id FKs.
DROP TABLE IF EXISTS public.interviews CASCADE;
DROP TABLE IF EXISTS public.offers     CASCADE;
DROP TABLE IF EXISTS public.applicants CASCADE;

-- Confirm gone
SELECT table_name
FROM information_schema.tables
WHERE table_schema='public'
  AND table_name IN ('applicants','interviews','offers');
