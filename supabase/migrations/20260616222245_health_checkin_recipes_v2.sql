INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, composio_action, internal_handler,
  cron_expression, input_config, is_active
) VALUES
(
  '126794dd-25ff-47d2-a436-724499733365',
  'Health Checkin — Daily Prompt',
  'Posts the 7:00 PM CT health goal question to the PJS Agency Telegram group, every day (incl. weekends). DST self-correcting via local_time gate.',
  'cron',
  'INTERNAL',
  'team_health_checkin_prompt',
  '0 0,1 * * *',
  jsonb_build_object('local_time', '19:00', 'checkin_type', 'health_eve'),
  true
),
(
  '126794dd-25ff-47d2-a436-724499733365',
  'Health Checkin — Daily Compile',
  'Posts the 8:00 PM CT week-to-date health summary to the PJS Agency Telegram group, every day. DST self-correcting via local_time gate.',
  'cron',
  'INTERNAL',
  'team_health_checkin_compile',
  '0 1,2 * * *',
  jsonb_build_object('local_time', '20:00', 'checkin_type', 'health_eve'),
  true
);
