-- Peter directive 2026-09-07: nothing runs more often than hourly.
-- The runner ticks once an hour at :59 and fires every recipe whose slot came due
-- since its last run. Sub-hourly recipe schedules are normalized to hourly.
-- All other pg_cron jobs move to hourly or slower, each on its own minute.

CREATE OR REPLACE FUNCTION public.run_due_automation_recipes()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now    TIMESTAMPTZ := date_trunc('minute', NOW());
  v_from   TIMESTAMPTZ := date_trunc('minute', NOW()) - INTERVAL '119 minutes';
  v_recipe RECORD;
  v_fired  INTEGER := 0;
BEGIN
  -- Hourly tick (pg_cron job 1 runs at :59). A recipe is due when its cron
  -- expression matched any minute in the last two hours that is later than its
  -- last run. One fire per recipe per tick. Earliest slot first so same-hour
  -- sequences (ingest, then check) keep their designed order. The two-hour
  -- look-back means one skipped tick loses nothing; the last-run guard means a
  -- wider window never double-fires.
  FOR v_recipe IN
    SELECT r.id, r.agency_id, r.recipe_name, m.slot
    FROM public.automation_recipes r
    CROSS JOIN LATERAL (
      SELECT min(s.minute) AS slot
      FROM generate_series(v_from, v_now, INTERVAL '1 minute') AS s(minute)
      WHERE s.minute > COALESCE(
              r.last_run_at,
              (SELECT max(l.run_at) FROM public.automation_run_log l WHERE l.recipe_id = r.id),
              '-infinity'::timestamptz)
        AND public.cron_expression_matches(r.cron_expression, s.minute, r.timezone)
    ) m
    WHERE r.is_active = TRUE
      AND r.trigger_type = 'cron'
      AND r.cron_expression IS NOT NULL
      AND length(trim(r.cron_expression)) > 0
      AND m.slot IS NOT NULL
    ORDER BY m.slot, r.recipe_name
  LOOP
    BEGIN
      PERFORM public.run_automation_recipe(v_recipe.id, 'pg_cron');
      v_fired := v_fired + 1;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.automation_run_log (
        agency_id, recipe_id, status, error_message, output_summary, run_at
      ) VALUES (
        v_recipe.agency_id, v_recipe.id, 'failed', SQLERRM,
        'tick dispatch failed: ' || v_recipe.recipe_name, NOW()
      );
    END;
  END LOOP;

  RETURN v_fired;
END;
$function$;

-- Task reminders now run hourly, so look two hours ahead instead of one.
CREATE OR REPLACE FUNCTION public.dispatch_task_reminders()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_chat_id bigint;
  v_now timestamptz := NOW();
  v_recipe_id uuid;
  v_run_start timestamptz := clock_timestamp();
  v_task RECORD;
  v_msg text;
  v_local_due text;
  v_count int := 0;
  v_ids uuid[] := ARRAY[]::uuid[];
  v_out jsonb;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
  WHERE recipe_name = 'Task Reminder Dispatcher' AND agency_id = v_agency_id LIMIT 1;

  SELECT t.telegram_user_id INTO v_chat_id
  FROM public.team t
  WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner'
    AND t.is_excluded_paper_newt_bot = false AND t.telegram_user_id IS NOT NULL
  LIMIT 1;

  IF v_chat_id IS NULL THEN
    v_out := jsonb_build_object('records_processed', 0,
      'output_summary', 'skipped: no owner telegram_user_id on team (paper_newt_bot channel)');
    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
      VALUES (v_agency_id, v_recipe_id, v_now, 'success', 0, v_out->>'output_summary',
              ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_run_start)))::int);
    END IF;
    RETURN v_out;
  END IF;

  FOR v_task IN
    SELECT id, title, due_at, priority, task_type FROM public.tasks
    WHERE agency_id = v_agency_id AND remind_via_telegram = true AND due_at IS NOT NULL
      AND reminded_at IS NULL AND status = 'open' AND due_at <= v_now + INTERVAL '120 minutes'
    ORDER BY due_at LIMIT 50
  LOOP
    v_local_due := to_char(v_task.due_at AT TIME ZONE 'America/Chicago', 'FMDay Mon FMDD, FMHH12:MI AM');
    v_msg := format(E'⏰ Task reminder\n\n%s\n\nDue: %s CT\nPriority: %s\n\nOpen Newtworks → Tasks & Goals',
      v_task.title, v_local_due, COALESCE(v_task.priority, 'medium'));
    BEGIN
      PERFORM public.telegram_send_message_v2(v_chat_id, v_msg, 'paper_newt');
      UPDATE public.tasks SET reminded_at = v_now WHERE id = v_task.id;
      v_ids := array_append(v_ids, v_task.id);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'dispatch_task_reminders: telegram send failed for task % (%): %', v_task.id, v_task.title, SQLERRM;
    END;
  END LOOP;

  v_out := jsonb_build_object('records_processed', v_count,
    'output_summary', CASE WHEN v_count = 0 THEN 'no tasks due within 2 hours'
                            ELSE format('sent %s reminder(s)', v_count) END,
    'task_ids', to_jsonb(v_ids));

  IF v_recipe_id IS NOT NULL THEN
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_now, 'success', v_count, v_out->>'output_summary',
            ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_run_start)))::int);
  END IF;
  RETURN v_out;
END;
$function$;

-- Recipe schedules: nothing sub-hourly. Hour ranges and days are kept as designed.
UPDATE public.automation_recipes SET cron_expression = '0 * * * *', updated_at = NOW()
 WHERE cron_expression IN ('*/2 * * * *', '*/5 * * * *', '*/15 * * * *', '*/30 * * * *', '7,37 * * * *');
UPDATE public.automation_recipes SET cron_expression = '0 13-23 * * 1-6', updated_at = NOW()
 WHERE cron_expression = '*/30 13-23 * * 1-6';
UPDATE public.automation_recipes SET cron_expression = '0 6-23 * * 0,1,6', updated_at = NOW()
 WHERE cron_expression = '*/15 6-23 * * 0,1,6';
UPDATE public.automation_recipes SET cron_expression = '0 15-19 * * 5', updated_at = NOW()
 WHERE cron_expression = '0,30 15-19 * * 5';
-- An annual refresh was running every hour for three months. Once a day is plenty.
UPDATE public.automation_recipes SET cron_expression = '0 6 * 11,12,1 *', updated_at = NOW()
 WHERE cron_expression = '0 * * 11,12,1 *';

-- pg_cron: hourly or slower, one job per minute slot.
SELECT cron.alter_job(job_id := 1,  schedule := '59 * * * *');          -- automation runner
SELECT cron.alter_job(job_id := 2,  schedule := '10 * * * *');          -- time off notifications
SELECT cron.alter_job(job_id := 3,  schedule := '20 * * * *');          -- time off to calendar
SELECT cron.alter_job(job_id := 8,  schedule := '30 */3 * * *');        -- huddle calendar sync
SELECT cron.alter_job(job_id := 12, schedule := '40 6-23 * * 0,1,6');   -- CPR send verification, send days only
SELECT cron.alter_job(job_id := 15, schedule := '45 * * * *');          -- task reminders
SELECT cron.alter_job(job_id := 17, schedule := '50 * * * *');          -- new applicant ping
