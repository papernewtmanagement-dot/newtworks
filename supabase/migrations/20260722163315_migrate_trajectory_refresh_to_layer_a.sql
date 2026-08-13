-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-22 16:33:15 UTC (ledger name: migrate_trajectory_refresh_to_layer_a) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260722163315.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Third and final Layer B CT-anchored job into Layer A. Current pg_cron
-- schedule '0 13 * * 0' = Sun 8 AM CDT / 7 AM CST — DST drift of 1 hr.
-- Peter directive: everything CT with the tz column. Migrate.

CREATE OR REPLACE FUNCTION public.run_team_trajectory_refresh_weekly(
  p_agency_id uuid, p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  -- Full recompute of trajectory metrics for this agency
  RETURN public.team_trajectory_recompute(p_agency_id, true);
END;
$$;

-- Create Layer A recipe. Time: Sun 8 AM CT (matches historical CDT firing).
-- This runs AFTER "Weekly Team Trajectory Summaries" (Sun 7 AM CT) — same
-- order that was working in CDT all summer.
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone,
  composio_action, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Team Trajectory Recompute',
  'Sunday 8 AM CT: full recompute of team trajectory metrics for the agency. Wraps team_trajectory_recompute(agency_id, force=true). Runs 1 hr after "Weekly Team Trajectory Summaries" — preserves CDT firing order (was pg_cron Sun 13 UTC before 2026-07-22 migration).',
  'cron', '0 8 * * 0', 'America/Chicago',
  'INTERNAL', 'run_team_trajectory_refresh_weekly',
  '{}'::jsonb, true
);

-- Cut the pg_cron entry
SELECT cron.unschedule('weekly_team_trajectory_refresh');
