-- Follow-up steps (tag-missing, compile) measure their recovery window from the
-- time the reminder actually went out, not from the wall clock. Closes the gap
-- where a reminder recovered late (say 1:20 pm) left the summary with no window
-- to post in. Tag-missing also never runs after the summary is already out.
-- Normal days unchanged: reminder at :00, follow-ups at :15 and :30.

CREATE OR REPLACE FUNCTION public.team_checkin_follow_up_window_open(
  p_agency_id uuid, p_checkin_type text, p_after_reminder interval, p_max_lag_minutes integer DEFAULT 90)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
  -- True from (reminder sent + offset) until 90 minutes after that.
  SELECT EXISTS (
    SELECT 1 FROM public.team_checkin_runs
    WHERE agency_id = p_agency_id
      AND checkin_date = (now() AT TIME ZONE 'America/Chicago')::date
      AND checkin_type = p_checkin_type
      AND reminder_sent_at IS NOT NULL
      AND now() >= reminder_sent_at + p_after_reminder
      AND now() <  reminder_sent_at + p_after_reminder + make_interval(mins => p_max_lag_minutes)
  );
$function$;

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
       -- Rule 2: recovery, one attempt per tick, never while one is in flight.
       --   reminder: still not sent, 3 to 90 minutes past its locked time.
       --   tag-missing / compile: still not done, 15 / 30 minutes after the
       --   reminder actually went out, for up to 90 minutes after that.
       --   tag-missing never runs once the summary is out.
            step_done_at IS NULL
        AND last_run <= NOW() - INTERVAL '4 minutes'
        AND (
              (step = 'reminder' AND public.team_checkin_is_within_recovery_window(local_time))
           OR (step <> 'reminder'
               AND reminder_sent_at IS NOT NULL
               AND NOW() >= reminder_sent_at + after_reminder
               AND NOW() <  reminder_sent_at + after_reminder + INTERVAL '90 minutes'
               AND (step = 'compile' OR compile_results_at IS NULL))
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
  ELSIF public.team_checkin_follow_up_window_open(p_agency_id, v_checkin_type, INTERVAL '15 minutes')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'tag_missing')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'compile') THEN
    -- Recovery: 15 to 105 minutes after the reminder actually went out, and only
    -- while the summary is not out yet.
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

-- Compile: recovery window now runs from the reminder's actual send time.
-- Only the guard block changes; the body is unchanged from migrations
-- daily_kickoff_commits / checkin_summaries_delete_prior.
CREATE OR REPLACE FUNCTION public.team_checkin_compile_results(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_dow int; v_text text; v_response jsonb; v_message_id bigint;
  v_type_label text; v_block record; v_cpr_id uuid; v_is_recovery boolean := false;
  v_parse_mode text := NULL;
  v_pfa_url text := 'https://newtworks.vercel.app/pfa';
  v_wrapup_url text := 'https://newtworks.vercel.app/processes/1590689841';
  v_reminder_msg_id bigint; v_tag_msg_id bigint; v_midday_summary_msg_id bigint;
  v_commits text;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_follow_up_window_open(p_agency_id, v_checkin_type, INTERVAL '30 minutes')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'compile') THEN
    -- Recovery: 30 to 120 minutes after the reminder actually went out.
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to compile');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;

  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  SELECT reminder_message_id, tag_missing_message_id
    INTO v_reminder_msg_id, v_tag_msg_id
  FROM public.team_checkin_runs
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  v_type_label := CASE v_checkin_type WHEN 'eod' THEN 'EOD' ELSE initcap(v_checkin_type) END;

  v_cpr_id := public.weekly_cpr_upsert_in_progress(p_agency_id, v_today);

  SELECT * INTO v_block FROM public.render_team_status_block(
    p_agency_id, v_today, v_checkin_type,
    '📊 ' || v_type_label || ' ' || to_char(v_today, 'Mon DD'));
  v_text := v_block.block_text;

  IF v_block.encouragement_text IS NOT NULL THEN
    v_text := v_text || E'\n' || v_block.encouragement_text;
  END IF;

  -- The team's commits and whether each was hit. The reminder that listed
  -- them is deleted below, so they ride on the results (Peter 2026-09-11).
  IF v_checkin_type IN ('midday', 'eod') THEN
    v_commits := public.render_daily_commits_block(p_agency_id, v_today, true, v_checkin_type = 'eod');
    IF v_commits IS NOT NULL THEN
      v_text := v_text || E'\n\n' || v_commits;
    END IF;
  END IF;

  -- Reminder is about to be deleted, so anything that still needs saying moves
  -- onto the results message. Deposit records is the one (Peter 2026-09-10).
  IF v_checkin_type = 'eod' THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n💰 <a href="' || v_pfa_url || E'">Don''t forget deposit records</a>';
  END IF;

  IF v_checkin_type = 'eod' AND v_dow = 5 THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n📝 Weekly wrapup — email paper.newt.management@gmail.com. '
      || E'What to include: <a href="' || v_wrapup_url || E'">Daily Wrap-up</a>';
  END IF;

  -- Delete the reminder and the tag-missing nudge, then post the results fresh.
  -- Editing the reminder in place was tried 2026-09-10 and reverted the same day:
  -- an edit fires no notification, so the team never saw the numbers land.
  -- Delete-then-post keeps the channel to one bubble AND keeps the ping.
  IF v_reminder_msg_id IS NOT NULL THEN
    PERFORM public.telegram_delete_message(v_chat_id, v_reminder_msg_id);
  END IF;
  IF v_tag_msg_id IS NOT NULL THEN
    PERFORM public.telegram_delete_message(v_chat_id, v_tag_msg_id);
  END IF;

  -- LOCKED (Peter 2026-09-10): the EOD summary replaces that day's midday summary.
  IF v_checkin_type = 'eod' THEN
    SELECT compile_results_message_id INTO v_midday_summary_msg_id
    FROM public.team_checkin_runs
    WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = 'midday';
    IF v_midday_summary_msg_id IS NOT NULL THEN
      PERFORM public.telegram_delete_message(v_chat_id, v_midday_summary_msg_id);
    END IF;
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET compile_results_at = now(),
      compile_results_message_id = v_message_id,
      updated_at = now(),
      responders_count = v_block.fresh_count,
      expected_count = v_block.expected_count
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_block.fresh_count + v_block.carried_count,
    'output_summary', format('%s compile%s: %s/%s reporting; team %s/%s; cpr_id=%s',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
      v_block.fresh_count, v_block.expected_count,
      v_block.team_total_quotes, v_block.team_total_sales, v_cpr_id));
END;
$function$;
