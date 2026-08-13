-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-12 03:17:40 UTC (ledger name: team_assessments_add_wall_clock_durations) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260712031740.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Wall-clock durations captured from HireGauge History page (Start → Complete elapsed).
-- Distinct from lss_*_speed_seconds columns which measure per-section active-answer time only.
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS cts_wall_duration_seconds int,
  ADD COLUMN IF NOT EXISTS lss_wall_duration_seconds int,
  ADD COLUMN IF NOT EXISTS vct_wall_duration_seconds int;

COMMENT ON COLUMN public.team_assessments.cts_wall_duration_seconds IS
  'Total elapsed seconds from HireGauge "Started CTS" to "Completed CTS" (wall clock, minute-granularity source). Includes reading, thinking, submission time. Distinct from per-item response latency (not stored).';

COMMENT ON COLUMN public.team_assessments.lss_wall_duration_seconds IS
  'Total elapsed seconds from HireGauge "Started LSS" to "Completed LSS" (wall clock). Includes reading and think time. NOT equivalent to sum of lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds, which measure narrower active-answer time.';

COMMENT ON COLUMN public.team_assessments.vct_wall_duration_seconds IS
  'Total elapsed seconds from HireGauge "Started VCT" to "Completed VCT" (wall clock). Purpose of VCT section not yet characterized.';
