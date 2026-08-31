-- Register the Win the Quarter close alongside the other two quarter-close recipes.
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, is_active, internal_handler, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365',
  'Quarter Close — Win the Quarter trip',
  'Runs at Q-close Saturday 23:59 CT. Finalises the Win the Quarter trip: reads the final '
  'trip pot from the pool carveout, picks the Quarter MVP by total Sales Points for the '
  'quarter, splits 50 percent to the MVP and 50 percent evenly among the rest, and writes '
  'each person''s dollar figure onto their CPR row for the final week of the quarter. '
  'Anyone who has given notice is excluded. No trip below the 9-of-13 win floor.',
  'cron', '59 23 * * 6', 'INTERNAL', true, 'quarter_close_wtq_dispatcher', 'America/Chicago'
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler='quarter_close_wtq_dispatcher');

-- The raise-review description still says "Does not change pay." It does change pay —
-- quarter_close_raise_review writes the new rate to team.pay_rate. Peter made that call
-- 2026-08-28; the description was never updated to match.
UPDATE public.automation_recipes
SET recipe_description = 'Runs at Q-close Saturday 23:59 CT. Measures every seat against '
    'the published raise ladder in pay_scale, logs the review to raise_review_log, APPLIES '
    'the new rate to team.pay_rate, and raises a task. Guards: only moves pay up, rejects '
    'any single step over $3/hr.',
    updated_at = now()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler='quarter_close_raise_review_dispatcher';
