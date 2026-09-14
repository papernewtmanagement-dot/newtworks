-- The summary has to land after the second nag, so it moves from :30 to :50.
-- Reminder :00 -> nag +20 -> nag +40 -> summary :50. The summary still deletes
-- the reminder and any standing nag before it posts.
UPDATE public.automation_recipes
SET input_config = jsonb_set(input_config, '{local_time}', '"12:50"'), updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_compile_results'
  AND input_config->>'checkin_type' = 'midday';

UPDATE public.automation_recipes
SET input_config = jsonb_set(input_config, '{local_time}', '"17:50"'), updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_compile_results'
  AND input_config->>'checkin_type' = 'eod';

-- team_checkin_tag_missing no longer reads local_time (it works off minutes since
-- the reminder), but leaving :15 on the row would misdescribe when it fires.
UPDATE public.automation_recipes
SET input_config = jsonb_set(input_config, '{local_time}', '"12:20"'), updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_tag_missing'
  AND input_config->>'checkin_type' = 'midday';

UPDATE public.automation_recipes
SET input_config = jsonb_set(input_config, '{local_time}', '"17:20"'), updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_tag_missing'
  AND input_config->>'checkin_type' = 'eod';

-- Minute 50 added to the existing tick so the summary slot exists. No new job.
SELECT cron.alter_job(23, schedule => '0,15,20,25,30,40,50 0,13,14,17,18,19,22,23 * * 1-6');