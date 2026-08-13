-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-07 21:43:12 UTC (ledger name: git_branch_sync_state) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260807214312.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Tiny tracker for the db->main branch merge cadence. One row per branch pair.
-- Purpose: let any Claude session (not just the one that set up db-routing)
-- know at a glance whether db is overdue for a merge into main, instead of
-- re-deriving it from scratch via GitHub compare calls every time.
CREATE TABLE IF NOT EXISTS public.git_branch_sync_state (
  agency_id uuid NOT NULL,
  branch text NOT NULL,
  base_branch text NOT NULL,
  merge_interval_minutes int NOT NULL DEFAULT 60,
  last_checked_at timestamptz,
  last_merged_at timestamptz,
  last_merged_sha text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, branch)
);

INSERT INTO public.git_branch_sync_state
  (agency_id, branch, base_branch, merge_interval_minutes, last_checked_at, last_merged_at, last_merged_sha)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'db', 'main', 60, now(), '2026-08-07 17:37:31+00', '8476e89c9f425968cc30e4c84e9b4e786464b477')
ON CONFLICT (agency_id, branch) DO NOTHING;
