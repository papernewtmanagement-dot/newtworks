-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 23:51:25 UTC (ledger name: hiring_candidates_v2_default_true) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801235125.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Peter clarification 2026-08-01: the v1/v2 parallel-columns setup was
-- always meant to preserve scoring for ALREADY-COMPLETED v1 candidates
-- while v2 was being built -- NOT to give new candidates a choice. Going
-- forward, every new candidate should only ever be served v2. Setting the
-- default to true means no manual flag-flip is needed per candidate (fixes
-- the "no UI toggle exists" gap by removing the need for one entirely).
-- Existing rows (already-completed v1 candidates, v2=false) are untouched
-- -- their v1 scores keep computing and displaying exactly as before.
ALTER TABLE public.hiring_candidates
  ALTER COLUMN v2 SET DEFAULT true;

COMMENT ON COLUMN public.hiring_candidates.v2 IS
  'True (default, 2026-08-01 onward) = served the v2 assessment. False = v1/CTS-era candidate, scored under the legacy path -- these rows are historical only and are never re-routed. v1 delivery is not offered to new candidates; only existing false rows exist because they predate the default flip.';
