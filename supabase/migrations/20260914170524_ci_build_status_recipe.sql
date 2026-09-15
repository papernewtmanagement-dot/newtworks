-- Rides the existing hourly runner tick. No new pg_cron job.
-- Minute is 59 because the runner fires at H:59, so the expression tells the truth.
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, trigger_type, cron_expression, timezone,
   internal_handler, composio_action, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'CI Build Status Watch',
       'cron',
       '59 */3 * * *',
       'America/Chicago',
       'check_ci_build_status',
       'INTERNAL',
       true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND internal_handler = 'check_ci_build_status'
);
