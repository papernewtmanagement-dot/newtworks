-- Team check-in dispatcher: retry a failed or missed step inside its 90-minute
-- recovery window, and run tag-missing / compile off the time the reminder
-- actually went out (15 / 30 minutes later), not only off the cron minute.
--
-- Origin 2026-09-11: the noon reminder failed (the database API layer answered
-- Gateway Timeout for about 30 minutes), nothing retried it, and tag-missing and
-- compile then skipped because no reminder was out. No midday summary that day.
--
-- Normal days are unchanged. The reminder fires at its locked minute (rule 1).
-- Tag-missing and compile also fire at their locked minutes, because those are
-- exactly 15 and 30 minutes after the reminder. Rule 2 only wakes up when a
-- step is still not done more than 3 minutes past its locked time.

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
      SELECT r.id, r.agency_id, r.recipe_name, r.cron_expression, r.timezone,
             r.input_config->>'checkin_type' AS checkin_type,
             r.input_config->>'local_time'   AS local_time,
             COALESCE(r.last_run_at,
                      (SELECT max(l.run_at) FROM public.automation_run_log l WHERE l.recipe_id = r.id),
                      '-infinity'::timestamptz) AS last_run,
             CASE r.internal_handler
               WHEN 'team_checkin_send_reminder'   THEN 'reminder'
               WHEN 'team_checkin_tag_missing'     THEN 'tag_missing'
               ELSE 'compile' END AS step,
             CASE r.internal_handler
               WHEN 'team_checkin_tag_missing'     THEN INTERVAL '15 minutes'
               WHEN 'team_checkin_compile_results' THEN INTERVAL '30 minutes'
               ELSE INTERVAL '0 minutes' END AS after_reminder
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
             run.reminder_sent_at,
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
       -- Rule 2: recovery. The step is still not done, we are 3 to 90 minutes
       -- past its locked time, the reminder it follows has gone out and its
       -- 15 / 30 minute spacing has passed, and nothing was dispatched in the
       -- last 4 minutes (one attempt per tick, never while one is in flight).
            step_done_at IS NULL
        AND public.team_checkin_is_within_recovery_window(local_time)
        AND (step = 'reminder'
             OR (reminder_sent_at IS NOT NULL AND NOW() >= reminder_sent_at + after_reminder))
        AND last_run <= NOW() - INTERVAL '4 minutes'
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

-- Tag-missing now stamps tag_missing_at even when it has nobody to tag, so the
-- dispatcher knows the step ran and does not re-fire it every tick.
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_text text; v_response jsonb; v_message_id bigint; v_missing record;
  v_missing_tags text := ''; v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0; v_is_recovery boolean := false;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_is_within_recovery_window(v_local_time)
        AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'tag_missing') THEN
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to tag');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  -- Pass v_today AND v_checkin_type so get_expected_teammates can apply both the
  -- time-off date filter and the half-day reminder-window mapping.
  FOR v_missing IN
    SELECT et.team_id AS id, et.first_name
    FROM public.get_expected_teammates(p_agency_id, 'work_checkin', v_today, v_checkin_type) et
    LEFT JOIN public.team_checkins tc ON tc.team_id = et.team_id AND tc.agency_id = p_agency_id
      AND tc.checkin_date = v_today AND tc.checkin_type = v_checkin_type
    WHERE tc.id IS NULL ORDER BY et.first_name
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
  END LOOP;

  IF v_missing_count = 0 THEN
    -- Step ran, nothing to send. Stamp it so the dispatcher does not retry.
    UPDATE public.team_checkin_runs
    SET tag_missing_at = now(), updated_at = now()
    WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type
      AND tag_missing_at IS NULL;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s tag-missing%s: silent (everyone already in)',
        v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END));
  END IF;

  v_text := '⏰ Still need numbers from: ' || trim(v_missing_tags);
  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET tag_missing_at = now(), tag_missing_message_id = v_message_id,
      tag_missing_team_ids = v_missing_ids, updated_at = now()
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object('records_processed', v_missing_count,
    'output_summary', format('%s tag-missing%s: %s pending',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END, v_missing_count));
END;
$function$;
