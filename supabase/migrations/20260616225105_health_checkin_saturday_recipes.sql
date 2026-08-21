-- 9 PM CT Saturday prompt: CDT 02:00 UTC, CST 03:00 UTC, day-of-week 6
-- 10 PM CT Saturday compile: CDT 03:00 UTC, CST 04:00 UTC, day-of-week 6
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, composio_action, internal_handler,
  cron_expression, input_config, is_active
) VALUES
(
  '126794dd-25ff-47d2-a436-724499733365',
  'Health Checkin — Saturday Prompt',
  'Posts the 9:00 PM CT Saturday week-closing health prompt to the PJS Agency Telegram group. Final check of the week. DST self-correcting via local_time gate.',
  'cron',
  'INTERNAL',
  'team_health_checkin_prompt',
  '0 2,3 * * 6',
  jsonb_build_object('local_time', '21:00', 'checkin_type', 'health_eve'),
  true
),
(
  '126794dd-25ff-47d2-a436-724499733365',
  'Health Checkin — Saturday Compile',
  'Posts the 10:00 PM CT Saturday end-of-week health summary to the PJS Agency Telegram group. Final wrap for the Sun-Sat week. DST self-correcting via local_time gate.',
  'cron',
  'INTERNAL',
  'team_health_checkin_compile',
  '0 3,4 * * 6',
  jsonb_build_object('local_time', '22:00', 'checkin_type', 'health_eve'),
  true
);
