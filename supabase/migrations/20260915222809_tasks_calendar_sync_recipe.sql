-- Rides the existing hourly runner tick at :59. No new cron job.
-- Safe to leave switched on: it returns immediately while gcal_tasks_calendar_id is blank.
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
   internal_handler, timezone, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Tasks Calendar Sync',
       'Puts the "complete at" time of a task on the Story Agency Tasks calendar and invites the person the task is assigned to. Edits the same event when the time moves, removes it when the time is cleared. Does nothing while settings.gcal_tasks_calendar_id is blank.',
       'cron', '59 * * * *',
       'tasks_calendar_dispatch', 'America/Chicago', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Tasks Calendar Sync');
