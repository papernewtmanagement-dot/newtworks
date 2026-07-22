-- Third Layer B CT-anchored job into Layer A. Sun 8 AM CT.
CREATE OR REPLACE FUNCTION public.run_team_trajectory_refresh_weekly(
  p_agency_id uuid, p_recipe_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN RETURN public.team_trajectory_recompute(p_agency_id, true); END;
$$;

INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone,
  composio_action, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Team Trajectory Recompute',
  'Sunday 8 AM CT: full recompute of team trajectory metrics for the agency.',
  'cron', '0 8 * * 0', 'America/Chicago', 'INTERNAL',
  'run_team_trajectory_refresh_weekly', '{}'::jsonb, true
);

SELECT cron.unschedule('weekly_team_trajectory_refresh');
