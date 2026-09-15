-- The compile step is gone and team_checkin_compile_results was dropped, so
-- these rows point at a handler that no longer exists.
-- Morning Compile has never run, so nothing references it. Delete it outright.
DELETE FROM public.automation_recipes
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_compile_results'
  AND input_config->>'checkin_type' = 'morning'
  AND NOT EXISTS (
    SELECT 1 FROM public.automation_run_log l
    WHERE l.recipe_id = public.automation_recipes.id);

-- Midday and EOD Compile carry 43 run-log rows between them, and
-- automation_run_log.recipe_id is ON DELETE NO ACTION, so deleting these rows
-- would mean destroying that history. They stay inactive. The note is here so a
-- future session does not reactivate a recipe whose handler is gone.
UPDATE public.automation_recipes
SET recipe_description = COALESCE(recipe_description || E'\n', '')
      || 'RETIRED 2026-09-14. There is no compile step any more: the midday and '
      || 'end-of-day messages are built and sent by team_checkin_send_reminder '
      || 'through team_checkin_build_results_message. The handler named on this '
      || 'row, team_checkin_compile_results, has been dropped. Do not reactivate. '
      || 'Kept only because automation_run_log rows point at it.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_compile_results';
