-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-22 16:31:18 UTC (ledger name: migrate_cpr_pg_cron_jobs_to_layer_a) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260722163118.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Migrate the 2 CT-anchored pg_cron jobs into Layer A automation_recipes.
-- Peter directive 2026-07-22 (final Layer B cleanup). Now everything scheduled
-- in one place with one mechanism.
--
-- The 2 recipe rows already exist as stubs (trigger_type='manual', cron=NULL) —
-- referenced by the SQL functions for log anchoring. Just fill them in and
-- flip trigger_type='cron'.
--
-- run_internal_recipe requires handler signature (agency_id uuid, recipe_id uuid) → jsonb,
-- but try_send_weekly_cpr_recap() and nudge_peter_for_cpr_drafts() take no args.
-- Solution: thin wrapper functions with the right signature.

CREATE OR REPLACE FUNCTION public.run_weekly_cpr_auto_send(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- Wrapper for Layer A dispatch (run_internal_recipe → this). Delegates to
  -- try_send_weekly_cpr_recap which contains its own eligibility + send logic.
  RETURN public.try_send_weekly_cpr_recap();
END;
$$;

CREATE OR REPLACE FUNCTION public.run_weekly_cpr_nudge_peter(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN public.nudge_peter_for_cpr_drafts();
END;
$$;

-- Fill in the recipe stubs so run_due_automation_recipes picks them up
UPDATE public.automation_recipes
SET trigger_type      = 'cron',
    cron_expression   = '0 6 * * 0,1,6',
    timezone          = 'America/Chicago',
    composio_action   = 'INTERNAL',
    internal_handler  = 'run_weekly_cpr_auto_send',
    input_config      = '{}'::jsonb,
    is_active         = true
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'weekly_cpr_auto_send';

UPDATE public.automation_recipes
SET trigger_type      = 'cron',
    cron_expression   = '0 18 * * 0,6',
    timezone          = 'America/Chicago',
    composio_action   = 'INTERNAL',
    internal_handler  = 'run_weekly_cpr_nudge_peter',
    input_config      = '{}'::jsonb,
    is_active         = true
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'weekly_cpr_nudge_peter';

-- Cut the pg_cron entries. Layer A now owns these fires.
SELECT cron.unschedule('weekly_cpr_auto_send');
SELECT cron.unschedule('weekly_cpr_nudge_peter');
