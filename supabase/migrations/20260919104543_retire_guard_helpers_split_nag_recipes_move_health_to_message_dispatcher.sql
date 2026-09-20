-- The two clock helpers now have no callers. Verified in pg_proc (only each
-- other) and in the repo (supabase/functions and src both clean — the only
-- match for local_time is a key the edge runner ignores).
DO $chk$
DECLARE v_callers int;
BEGIN
  SELECT count(*) INTO v_callers
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname NOT IN ('team_checkin_is_right_local_time','team_checkin_is_within_recovery_window')
    AND (pg_get_functiondef(p.oid) LIKE '%team_checkin_is_right_local_time(%'
      OR pg_get_functiondef(p.oid) LIKE '%team_checkin_is_within_recovery_window(%');
  IF v_callers > 0 THEN
    RAISE EXCEPTION 'refusing to drop: % database caller(s) still reference the clock guards', v_callers;
  END IF;
END $chk$;

DROP FUNCTION IF EXISTS public.team_checkin_is_right_local_time(text, integer);
DROP FUNCTION IF EXISTS public.team_checkin_is_within_recovery_window(text, integer);

-- local_time drove the guards and nothing else. It is what silently drifted out
-- of step with the cron expression and made the health messages stop. Gone, so
-- there is only one place a send time is written.
UPDATE public.automation_recipes
   SET input_config = input_config - 'local_time', updated_at = NOW()
 WHERE input_config ? 'local_time';

-- The second nag used to come from the catch-up path firing the same recipe
-- repeatedly. Now every fire time is written on a recipe, where it can be read.
UPDATE public.automation_recipes
   SET cron_expression = '20,40 12 * * 1-5', updated_at = NOW()
 WHERE recipe_name = 'Team Checkin — Midday Tag Missing';

UPDATE public.automation_recipes
   SET cron_expression = '20,40 17 * * 1-5', updated_at = NOW()
 WHERE recipe_name = 'Team Checkin — EOD Tag Missing';

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
   internal_handler, input_config, is_active, timezone)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — Midday Nag Retire',
   'Takes the midday nag down at 1 PM Central.',
   'cron', '0 13 * * 1-5', 'team_checkin_tag_missing',
   '{"checkin_type":"midday"}'::jsonb, true, 'America/Chicago'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — EOD Nag Retire',
   'Takes the end-of-day nag down at 6 PM Central.',
   'cron', '0 18 * * 1-5', 'team_checkin_tag_missing',
   '{"checkin_type":"eod"}'::jsonb, true, 'America/Chicago');

-- The health messages move onto the team-message dispatcher, which has no
-- look-back, so a missed tick can no longer post them an hour late.
-- pg_cron job 23 needs the UTC hours that cover every Central send time in both
-- standard and daylight time, and every day of the week: Saturday's 10 PM
-- Central health summary lands on Sunday in UTC.
--   8:25 AM CT -> 13:25 / 14:25 UTC      12:00, 12:20, 12:40, 1:00 PM CT -> 17-19 UTC
--   5:00, 5:20, 5:40, 6:00 PM CT -> 22-00 UTC    7:00-10:00 PM CT -> 00-04 UTC
SELECT cron.alter_job(23, schedule := '0,20,25,40 0,1,2,3,4,13,14,17,18,19,22,23 * * *');
