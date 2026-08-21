UPDATE public.automation_recipes
SET cron_expression = '0 0,1 * * 1-5',
    recipe_description = 'Posts the 7:00 PM CT health goal question to the PJS Agency Telegram group, weekdays only. DST self-correcting via local_time gate.',
    updated_at = now()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Health Checkin — Daily Prompt';

UPDATE public.automation_recipes
SET cron_expression = '0 1,2 * * 1-5',
    recipe_description = 'Posts the 8:00 PM CT week-to-date health summary to the PJS Agency Telegram group, weekdays only. DST self-correcting via local_time gate.',
    updated_at = now()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Health Checkin — Daily Compile';

-- Rename for accuracy now that they're weekday-only
UPDATE public.automation_recipes
SET recipe_name = 'Health Checkin — Weekday Prompt',
    updated_at = now()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Health Checkin — Daily Prompt';

UPDATE public.automation_recipes
SET recipe_name = 'Health Checkin — Weekday Compile',
    updated_at = now()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Health Checkin — Daily Compile';
