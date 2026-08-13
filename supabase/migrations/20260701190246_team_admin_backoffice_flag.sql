-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-01 19:02:46 UTC (ledger name: team_admin_backoffice_flag) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260701190246.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Explicit gate for admin/back-office team rows that should be excluded from
-- production, CPR, comp, scorecard, hours, surge/retention, and any team
-- roll-up. Complements existing per-context flags. Any team-facing query
-- must AND is_admin_backoffice = false.
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS is_admin_backoffice boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.team.is_admin_backoffice IS
  'True = admin/back-office only. Exclude from team_production, CPR, comp, scorecard, hours, surge/retention pool, team roll-up queries. Renewals + tasks still allowed (per-person data lives here).';

CREATE INDEX IF NOT EXISTS idx_team_active_producers
  ON public.team(agency_id)
  WHERE is_active = true AND is_admin_backoffice = false;
