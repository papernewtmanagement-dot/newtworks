-- Saturday health check-in fired at 21:00/22:00 CT, two hours later than the
-- weekday 19:00/20:00. Aligning Saturday to the weekday time.
-- The handlers gate on input_config.local_time, so cron_expression and
-- local_time must move together or every run skips as "wrong-DST cron fire".
UPDATE public.automation_recipes
SET cron_expression = '0 19 * * 6',
    input_config    = jsonb_set(input_config, '{local_time}', '"19:00"'),
    updated_at      = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Health Checkin — Saturday Prompt';

UPDATE public.automation_recipes
SET cron_expression = '0 20 * * 6',
    input_config    = jsonb_set(input_config, '{local_time}', '"20:00"'),
    updated_at      = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Health Checkin — Saturday Compile';
