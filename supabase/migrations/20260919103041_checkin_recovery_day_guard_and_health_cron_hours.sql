-- Fix 1: the check-in recovery branch had no day-of-week guard, so the morning
-- kickoff fired on Saturday 2026-09-19 at 08:40 ("[RECOVERY] dow=6"). The recovery
-- branch now also requires that the recipe's own cron expression actually matches
-- today at its intended local time.
CREATE OR REPLACE FUNCTION public.run_due_team_checkin_recipes()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now    TIMESTAMPTZ := date_trunc('minute', NOW());
  v_from   TIMESTAMPTZ := date_trunc('minute', NOW()) - INTERVAL '119 minutes';
  v_today  DATE := (NOW() AT TIME ZONE 'America/Chicago')::date;
  v_recipe RECORD;
  v_fired  INTEGER := 0;
BEGIN
  FOR v_recipe IN
    WITH cand AS (
      SELECT r.id, r.agency_id, r.recipe_name, r.cron_expression,
             COALESCE(r.timezone, 'America/Chicago') AS timezone,
             r.input_config->>'checkin_type' AS checkin_type,
             r.input_config->>'local_time'   AS local_time,
             COALESCE(r.last_run_at,
                      (SELECT max(l.run_at) FROM public.automation_run_log l WHERE l.recipe_id = r.id),
                      '-infinity'::timestamptz) AS last_run,
             CASE r.internal_handler
               WHEN 'team_checkin_send_reminder'   THEN 'reminder'
               WHEN 'team_checkin_tag_missing'     THEN 'tag_missing'
               ELSE 'compile' END AS step
      FROM public.automation_recipes r
      WHERE r.is_active = TRUE
        AND r.trigger_type = 'cron'
        AND r.internal_handler IN (
              'team_checkin_send_reminder',
              'team_checkin_tag_missing',
              'team_checkin_compile_results')
        AND r.cron_expression IS NOT NULL
        AND length(trim(r.cron_expression)) > 0
    ),
    scored AS (
      SELECT c.*,
             (SELECT min(s.minute)
                FROM generate_series(v_from, v_now, INTERVAL '1 minute') AS s(minute)
               WHERE s.minute > c.last_run
                 AND public.cron_expression_matches(c.cron_expression, s.minute, c.timezone)) AS slot,
             -- Is today a day this recipe is actually scheduled to run?
             -- Recovery must never fire on a day the cron expression excludes.
             public.cron_expression_matches(
               c.cron_expression,
               ((v_today::text || ' ' || COALESCE(c.local_time, '00:00'))::timestamp
                  AT TIME ZONE c.timezone),
               c.timezone) AS scheduled_today,
             run.reminder_sent_at,
             run.compile_results_at,
             CASE c.step
               WHEN 'reminder'    THEN run.reminder_sent_at
               WHEN 'tag_missing' THEN run.tag_missing_at
               ELSE run.compile_results_at END AS step_done_at
      FROM cand c
      LEFT JOIN public.team_checkin_runs run
        ON run.agency_id = c.agency_id
       AND run.checkin_date = v_today
       AND run.checkin_type = c.checkin_type
    )
    SELECT id, agency_id, recipe_name, slot
    FROM scored
    WHERE slot IS NOT NULL
       -- Rule 1: its scheduled minute has come and it has not run since.
       OR (
            last_run <= NOW() - INTERVAL '4 minutes'
        AND scheduled_today
        AND (
              -- Reminder: still not sent, 3 to 90 minutes past its locked time.
              (step = 'reminder'
               AND step_done_at IS NULL
               AND public.team_checkin_is_within_recovery_window(local_time))
              -- Nag: called every tick from +20 to +65 after the message went
              -- out. The nag function decides which stage is actually due.
           OR (step = 'tag_missing'
               AND reminder_sent_at IS NOT NULL
               AND NOW() >= reminder_sent_at + INTERVAL '20 minutes'
               AND NOW() <  reminder_sent_at + INTERVAL '65 minutes')
              -- Compile: kept for any recipe still wired to it.
           OR (step = 'compile'
               AND step_done_at IS NULL
               AND reminder_sent_at IS NOT NULL
               AND NOW() >= reminder_sent_at + INTERVAL '30 minutes'
               AND NOW() <  reminder_sent_at + INTERVAL '120 minutes')
        )
       )
    ORDER BY COALESCE(slot, v_now), recipe_name
  LOOP
    BEGIN
      PERFORM public.run_automation_recipe(v_recipe.id, 'pg_cron');
      v_fired := v_fired + 1;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.automation_run_log (
        agency_id, recipe_id, status, error_message, output_summary, run_at
      ) VALUES (
        v_recipe.agency_id, v_recipe.id, 'failed', SQLERRM,
        'checkin tick dispatch failed: ' || v_recipe.recipe_name, NOW()
      );
    END;
  END LOOP;

  RETURN v_fired;
END;
$function$;

-- Fix 2: these four cron hours were written one hour early on purpose, back when
-- the runner ticked at :59 and picked the slot up 59 minutes later. The tick moved
-- to :00 on 2026-09-17 and these were missed, so each one now fires a full hour
-- before its own intended local time and its guard rejects it as a wrong-DST fire.
-- Cron hour is now set to the intended local time.
UPDATE public.automation_recipes SET cron_expression = '0 19 * * 1-5', updated_at = NOW()
  WHERE recipe_name = 'Health Checkin — Weekday Prompt';
UPDATE public.automation_recipes SET cron_expression = '0 20 * * 1-5', updated_at = NOW()
  WHERE recipe_name = 'Health Checkin — Weekday Compile';
UPDATE public.automation_recipes SET cron_expression = '0 21 * * 6', updated_at = NOW()
  WHERE recipe_name = 'Health Checkin — Saturday Prompt';
UPDATE public.automation_recipes SET cron_expression = '0 22 * * 6', updated_at = NOW()
  WHERE recipe_name = 'Health Checkin — Saturday Compile';

-- Fix 3: same class. The Saturday week-close writer fires at 23:00 on Saturday
-- (cron 0 23 * * 6, which must stay on Saturday), but its intended local time still
-- said 23:59, left over from the :59 tick. It skipped on 2026-09-12 for this reason.
UPDATE public.automation_recipes
   SET input_config = jsonb_set(input_config, '{local_time}', '"23:00"'), updated_at = NOW()
 WHERE recipe_name = 'Weekly CPR — Saturday Outcome Writer';
