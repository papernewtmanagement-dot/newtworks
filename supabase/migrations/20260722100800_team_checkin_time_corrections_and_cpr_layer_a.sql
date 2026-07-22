-- Migrate the 2 CT-anchored pg_cron jobs into Layer A automation_recipes.
-- Peter directive 2026-07-22 (final Layer B cleanup). Now everything scheduled
-- in one place with one mechanism.
--
-- The 2 recipe rows already existed as stubs (trigger_type='manual', cron=NULL)
-- referenced by the SQL functions for log anchoring. Filled them in and
-- flipped trigger_type='cron'. Cut the pg_cron entries.

CREATE OR REPLACE FUNCTION public.run_weekly_cpr_auto_send(
  p_agency_id uuid, p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  RETURN public.try_send_weekly_cpr_recap();
END;
$$;

CREATE OR REPLACE FUNCTION public.run_weekly_cpr_nudge_peter(
  p_agency_id uuid, p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  RETURN public.nudge_peter_for_cpr_drafts();
END;
$$;

UPDATE public.automation_recipes
SET trigger_type='cron', cron_expression='0 6 * * 0,1,6', timezone='America/Chicago',
    composio_action='INTERNAL', internal_handler='run_weekly_cpr_auto_send',
    input_config='{}'::jsonb, is_active=true
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name='weekly_cpr_auto_send';

UPDATE public.automation_recipes
SET trigger_type='cron', cron_expression='0 18 * * 0,6', timezone='America/Chicago',
    composio_action='INTERNAL', internal_handler='run_weekly_cpr_nudge_peter',
    input_config='{}'::jsonb, is_active=true
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name='weekly_cpr_nudge_peter';

SELECT cron.unschedule('weekly_cpr_auto_send');
SELECT cron.unschedule('weekly_cpr_nudge_peter');
