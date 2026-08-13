-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-03 16:39:17 UTC (ledger name: widen_competency_floors_key_for_per_role) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260803163917.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Step 1 added hiregauge_competency_floors.role_category but left the primary key
-- at (agency_id, competency_name), making per-role floors structurally impossible.
-- Widen to include role_category. No rows are lost or modified.
-- Legacy rows carry role_category IS NULL (global); COALESCE sentinel keeps those unique too.

ALTER TABLE public.hiregauge_competency_floors
  DROP CONSTRAINT IF EXISTS hiregauge_competency_floors_pkey;

CREATE UNIQUE INDEX IF NOT EXISTS uq_hiregauge_competency_floors_agency_comp_role
  ON public.hiregauge_competency_floors
  (agency_id, competency_name, COALESCE(role_category, '__global__'));
