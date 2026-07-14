-- Task reminder dispatcher — fires within 60 min of due_at, once per task.
-- Direct-cron (pg_cron -> function), NOT via automation-runner (pure-SQL, no edge
-- fn dispatch needed). Recipe row registered with cron_expression=NULL /
-- trigger_type='manual' per op-rule "Recipe-row double-dispatch" so the runner
-- doesn't also pick it up.

CREATE OR REPLACE FUNCTION public.dispatch_task_reminders()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  SELECT id INTO v_recipe_id
  FROM public.automation_recipes
  WHERE recipe_name = 'Task Reminder Dispatcher' AND agency_id = v_agency_id
  LIMIT 1;

  SELECT ttm.telegram_user_id INTO v_chat_id
  FROM public.team_telegram_map ttm
  JOIN public.team t ON t.id = ttm.team_id
  WHERE t.agency_id = v_agency_id
    AND t.role_level = 'Owner'
    AND ttm.is_excluded_paper_newt_bot = false
  LIMIT 1;

  IF v_chat_id IS NULL THEN
    v_out := jsonb_build_object(
      'records_processed', 0,
      'output_summary', 'skipped: no owner chat_id in team_telegram_map (paper_newt_bot channel)');
    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
      VALUES (v_agency_id, v_recipe_id, v_now, 'success', 0, v_out->>'output_summary',
              ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_run_start)))::int);
    END IF;
    RETURN v_out;
  END IF;

  FOR v_task IN
    SELECT id, title, due_at, priority, task_type
    FROM public.tasks
    WHERE agency_id = v_agency_id
      AND remind_via_telegram = true
      AND due_at IS NOT NULL
      AND reminded_at IS NULL
      AND status = 'open'
      AND due_at <= v_now + INTERVAL '60 minutes'
    ORDER BY due_at
    LIMIT 50
  LOOP
    v_local_due := to_char(v_task.due_at AT TIME ZONE 'America/Chicago', 'FMDay Mon FMDD, FMHH12:MI AM');
    v_msg := format(
      E'⏰ Task reminder\n\n%s\n\nDue: %s CT\nPriority: %s\n\nOpen Newtworks → Tasks & Goals',
      v_task.title,
      v_local_due,
      COALESCE(v_task.priority, 'medium')
    );
    BEGIN
      PERFORM public.telegram_send_message_v2(v_chat_id, v_msg, 'paper_newt');
      UPDATE public.tasks SET reminded_at = v_now WHERE id = v_task.id;
      v_ids := array_append(v_ids, v_task.id);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'dispatch_task_reminders: telegram send failed for task % (%): %', v_task.id, v_task.title, SQLERRM;
    END;
  END LOOP;

  v_out := jsonb_build_object(
    'records_processed', v_count,
    'output_summary', CASE WHEN v_count = 0 THEN 'no tasks due within 60 min'
                            ELSE format('sent %s reminder(s)', v_count) END,
    'task_ids', to_jsonb(v_ids)
  );

  IF v_recipe_id IS NOT NULL THEN
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_now, 'success', v_count, v_out->>'output_summary',
            ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_run_start)))::int);
  END IF;

  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.dispatch_task_reminders() FROM PUBLIC, anon, authenticated;

INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type,
  cron_expression, composio_action, internal_handler, is_active
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'Task Reminder Dispatcher',
  'Every 5 min: DM Peter via @paper_newt_bot when an open task with remind_via_telegram=true is within 60 min of its due_at. Direct-cron (pg_cron -> SQL fn), not routed through automation-runner.',
  'manual',
  NULL,
  'INTERNAL',
  'dispatch_task_reminders',
  true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE recipe_name = 'Task Reminder Dispatcher'
    AND agency_id = '126794dd-25ff-47d2-a436-724499733365'
);

SELECT cron.unschedule(jobname) FROM cron.job WHERE jobname = 'task-reminder-tick';
SELECT cron.schedule(
  'task-reminder-tick',
  '*/5 * * * *',
  $cron$SELECT public.dispatch_task_reminders();$cron$
);
