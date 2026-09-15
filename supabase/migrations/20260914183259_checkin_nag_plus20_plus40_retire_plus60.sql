-- Telegram check-in rebuild (Peter spec 2026-09-14), part 3 of 4.
-- One nag function. Fires at +20 and +40 after the check-in message, each one
-- deleting the one before it. At +60 it deletes the standing nag and posts
-- nothing. No summary message follows any more, so +60 is the end of the line.
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_chat_id bigint;
  v_today date; v_text text; v_response jsonb; v_message_id bigint; v_missing record;
  v_missing_tags text := ''; v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0;
  v_run record; v_elapsed numeric; v_stage text;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';

  -- Peter: no morning nags, ever.
  IF v_checkin_type = 'morning' THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: morning never nags');
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  SELECT reminder_sent_at, tag_missing_at, tag_missing_message_id, compile_results_at
  INTO v_run
  FROM public.team_checkin_runs
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  IF v_run.reminder_sent_at IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no check-in message went out today, nothing to tag');
  END IF;

  v_elapsed := EXTRACT(EPOCH FROM (now() - v_run.reminder_sent_at)) / 60.0;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  IF v_elapsed >= 60 THEN
    v_stage := 'retire';
  ELSIF v_elapsed >= 40
        AND COALESCE(v_run.tag_missing_at, v_run.reminder_sent_at)
            < v_run.reminder_sent_at + INTERVAL '40 minutes' THEN
    v_stage := 'second';
  ELSIF v_elapsed >= 20 AND v_elapsed < 40 AND v_run.tag_missing_at IS NULL THEN
    v_stage := 'first';
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag: nothing due at +%s min',
        v_checkin_type, round(v_elapsed)));
  END IF;

  -- Take the standing nag down and post nothing.
  IF v_stage = 'retire' THEN
    IF public.team_checkin_delete_message(
         p_agency_id, v_chat_id, v_checkin_type, 'nag', v_today) IS NOT NULL THEN
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('%s nag: retired at +%s min',
          v_checkin_type, round(v_elapsed)));
    END IF;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag: nothing standing to retire', v_checkin_type));
  END IF;

  -- Pull anything the webhook missed before deciding who is short. This used to
  -- live on the compile step, which no longer exists.
  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  FOR v_missing IN
    SELECT m.team_id AS id, m.first_name
    FROM public.team_checkin_missing_acks(p_agency_id, v_today, v_checkin_type) m
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
  END LOOP;

  -- Everyone reacted. Take down any standing nag and go quiet.
  IF v_missing_count = 0 THEN
    PERFORM public.team_checkin_delete_message(
      p_agency_id, v_chat_id, v_checkin_type, 'nag', v_today);
    UPDATE public.team_checkin_runs
    SET tag_missing_at = now(), updated_at = now()
    WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag (+%s min): silent (everyone reacted)',
        v_checkin_type, round(v_elapsed)));
  END IF;

  -- Delete then repost, so the second nag replaces the first.
  PERFORM public.team_checkin_delete_message(
    p_agency_id, v_chat_id, v_checkin_type, 'nag', v_today);

  v_text := '👀 Still need a reaction from: ' || trim(v_missing_tags);
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
    'output_summary', format('%s nag (%s, +%s min): %s have not reacted',
      v_checkin_type, v_stage, round(v_elapsed), v_missing_count));
END;
$function$;


-- The dispatcher has to keep calling the nag across the whole window, because
-- the nag itself decides what is due from how long ago the message went out.
-- The old rule stopped as soon as tag_missing_at was set, so the second nag and
-- the +60 retire never fired at all.
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