-- Revert. Peter's Saturday times are 21:00 / 22:00 CT and were never up for change.
UPDATE public.automation_recipes
SET cron_expression = '0 21 * * 6',
    input_config    = jsonb_set(input_config, '{local_time}', '"21:00"'),
    updated_at      = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Health Checkin — Saturday Prompt';

UPDATE public.automation_recipes
SET cron_expression = '0 22 * * 6',
    input_config    = jsonb_set(input_config, '{local_time}', '"22:00"'),
    updated_at      = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Health Checkin — Saturday Compile';
