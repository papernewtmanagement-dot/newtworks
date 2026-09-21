-- Both ride the hourly runner tick. composio_action must be the literal
-- INTERNAL or the runner walks straight past the internal branch and fails
-- every run with "has no composio_connection set" — six recipes sat broken
-- that way until 2026-09-18.
--
-- Notices run through the working day so a caller hears within the hour of
-- the candidate accepting. Escalation runs once on a weekday morning: it
-- emails candidates, and nothing about it needs to happen twice in a day.

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
   composio_action, internal_handler, is_active, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Onboarding — reference caller notices',
       'Emails whoever is calling a candidate references once all the contacts are in, then nags Telegram route admin daily from 48 hours on while a number still has not been tried.',
       'cron', '0 8-18 * * *', 'INTERNAL', 'hiring_reference_caller_notices', true, 'America/Chicago'
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'hiring_reference_caller_notices');

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
   composio_action, internal_handler, is_active, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Onboarding — reference escalation',
       'Marks a reference unreachable after three attempts, emails the candidate for help, reopens the same contacts three days later for three more attempts, sends one final email, then pauses the reference check.',
       'cron', '0 10 * * 1-5', 'INTERNAL', 'hiring_reference_escalation', true, 'America/Chicago'
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'hiring_reference_escalation');
