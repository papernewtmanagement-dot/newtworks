-- Weekly Sunday run, after the team trajectory refresh (08:00 CT) so the thirteen-week
-- averages are settled for the week that just closed. Week boundary is Sunday-Saturday.
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
   composio_action, internal_handler, is_active, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Sales Points Band Drop Watcher',
       'Every Sunday, checks each manager-tier teammate''s rolling thirteen-week Sales Points rating. Raises an alert when someone drops into Caution (documented coaching conversation plus a weekly one-on-one) or Danger (signed improvement plan, back to Good within thirteen weeks). Resolves the alert automatically once the rating returns to Good or better.',
       'cron', '0 9 * * 0', 'INTERNAL', 'sales_points_band_drop_watcher', true, 'America/Chicago'
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'sales_points_band_drop_watcher'
);
