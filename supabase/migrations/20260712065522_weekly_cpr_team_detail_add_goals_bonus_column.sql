-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-12 06:55:22 UTC (ledger name: weekly_cpr_team_detail_add_goals_bonus_column) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260712065522.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Goals bonus column: $10 per All-Star crossing + $10 per Trailblazer + $10 if 1%-gain vs prior 13wk avg SP.
-- Computed downstream by write_weekly_comp_v2 after audit_weekly_leaderboard_crossings runs.
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS goals_bonus numeric NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.weekly_cpr_team_detail.goals_bonus IS
'Weekly $ goals bonus computed by write_weekly_comp_v2 after audit_weekly_leaderboard_crossings runs.
Formula: $10 per all_star_crossings row + $10 per trailblazer_crossings row + $10 if this-week new SP >= 1.01 * avg new SP over prior 13 weeks.';
