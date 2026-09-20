-- ONE SCHEDULER. Peter directive 2026-09-19.
-- Before this, three separate layers decided whether a team message went out:
-- the cron expression, a clock re-check inside each handler
-- (team_checkin_is_right_local_time, 3-minute tolerance) that silently refused
-- to send, and a catch-up path that re-sent late without checking the day.
-- They disagreed with each other and produced a Saturday kickoff and two silent
-- health messages. Layers two and three are removed. The cron expression is now
-- the only thing that decides.

-- One list of the handlers that send team-facing Telegram messages, in one place,
-- used by both dispatchers so they can never drift apart.
CREATE OR REPLACE FUNCTION public.is_team_message_handler(p_handler text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(p_handler, '') IN (
    'team_checkin_send_reminder',
    'team_checkin_tag_missing',
    'team_checkin_compile_results',
    'team_health_checkin_prompt',
    'team_health_checkin_compile')
$$;

COMMENT ON FUNCTION public.is_team_message_handler(text) IS
'The handlers that post to the team Telegram channel. Owned by pg_cron job 23
(run_due_team_checkin_recipes) and excluded from job 1 (run_due_automation_recipes).
Two dispatchers firing the same recipe sends the message twice.';

-- Team-facing dispatcher: exact minute only. Five-minute look-back, which covers
-- the tick itself and nothing more. A missed tick means a missed message, by design.
CREATE OR REPLACE FUNCTION public.run_due_team_checkin_recipes()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now    TIMESTAMPTZ := date_trunc('minute', NOW());
  v_from   TIMESTAMPTZ := date_trunc('minute', NOW()) - INTERVAL '5 minutes';
  v_recipe RECORD;
  v_fired  INTEGER := 0;
BEGIN
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
        AND public.cron_expression_matches(
              r.cron_expression, s.minute, COALESCE(r.timezone, 'America/Chicago'))
    ) m
    WHERE r.is_active = TRUE
      AND r.trigger_type = 'cron'
      AND r.cron_expression IS NOT NULL
      AND length(trim(r.cron_expression)) > 0
      AND public.is_team_message_handler(r.internal_handler)
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
        'checkin tick dispatch failed: ' || v_recipe.recipe_name, NOW()
      );
    END;
  END LOOP;

  RETURN v_fired;
END;
$function$;

-- General runner: same single list, so the health recipes move over cleanly.
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
  -- Hourly tick (pg_cron job 1 runs on the hour). A recipe is due when its
  -- cron expression matched any minute in the last two hours that is later
  -- than its last run. One fire per recipe per tick. Earliest slot first so
  -- same-hour sequences (ingest, then check) keep their designed order.
  --
  -- Team-facing message recipes are EXCLUDED via is_team_message_handler().
  -- They belong to run_due_team_checkin_recipes() on pg_cron job 23, which has
  -- no look-back. Do not add those handlers back here.
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
      AND NOT public.is_team_message_handler(r.internal_handler)
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

-- Kickoff / midday / EOD sender: guard and recovery label removed.
CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_chat_id bigint;
  v_today date; v_dow int; v_text text; v_response jsonb; v_message_id bigint;
  v_built record; v_send_text text;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';

  IF v_checkin_type NOT IN ('morning', 'midday', 'eod') THEN
    RAISE EXCEPTION 'Invalid checkin_type: %', v_checkin_type;
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';
  IF v_chat_id IS NULL THEN RAISE EXCEPTION 'telegram_team_group_chat_id not set'; END IF;

  -- Kept from the old compile step so the in-progress CPR row still gets made.
  IF v_checkin_type IN ('midday', 'eod') THEN
    PERFORM public.weekly_cpr_upsert_in_progress(p_agency_id, v_today);
  END IF;

  SELECT * INTO v_built FROM public.team_message_build(p_agency_id, v_checkin_type, v_today);
  v_text := v_built.message_text;

  -- The EOD message replaces the midday one; the kickoff takes down the prior EOD.
  IF v_checkin_type = 'eod' THEN
    PERFORM public.team_checkin_delete_message(p_agency_id, v_chat_id, 'midday', 'reminder', v_today);
  ELSIF v_checkin_type = 'morning' THEN
    PERFORM public.team_checkin_delete_message(p_agency_id, v_chat_id, 'eod', 'reminder', NULL, v_today);
  END IF;

  -- Morning sends the composed text; the marker version is what gets stored.
  IF v_checkin_type = 'morning' THEN
    v_send_text := public.kickoff_compose_message(p_agency_id, v_today, v_text);
  ELSE
    v_send_text := v_text;
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_send_text, v_built.parse_mode);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type, reminder_sent_at, reminder_message_id,
    reminder_text, expected_count
  ) VALUES (p_agency_id, v_today, v_checkin_type, now(), v_message_id, v_text, v_built.expected_count)
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        expected_count = COALESCE(EXCLUDED.expected_count, public.team_checkin_runs.expected_count),
        updated_at = now();

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('%s sent (msg_id=%s, dow=%s)',
      v_checkin_type, v_message_id, v_dow));
END;
$function$;

-- Health prompt: guard and recovery label removed.
CREATE OR REPLACE FUNCTION public.team_health_checkin_prompt(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_chat_id bigint; v_today date;
  v_text text; v_response jsonb; v_message_id bigint; v_quote record;
BEGIN
  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';
  IF v_chat_id IS NULL THEN RAISE EXCEPTION 'telegram_team_group_chat_id not set'; END IF;

  SELECT quote_text, attribution, video_url INTO v_quote
  FROM public.health_quotes
  WHERE agency_id = p_agency_id AND is_active = true AND pool = 'health_eve'
  ORDER BY random() LIMIT 1;

  v_text := E'💪 Exercise today? X/5 or yes/no';

  IF v_quote.quote_text IS NOT NULL THEN
    v_text := v_text || E'\n\n"' || v_quote.quote_text || '"';
    IF v_quote.attribution IS NOT NULL THEN
      v_text := v_text || ' — ' || v_quote.attribution;
    END IF;
    IF v_quote.video_url IS NOT NULL THEN
      v_text := v_text || E'\n▶️ ' || v_quote.video_url;
    END IF;
  END IF;

  -- Take down the prior day's health summary (Peter 2026-09-14).
  PERFORM public.team_checkin_delete_message(
    p_agency_id, v_chat_id, 'health_eve', 'summary', NULL, v_today);

  v_response := public.telegram_send_message(v_chat_id, v_text);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type, reminder_sent_at, reminder_message_id, reminder_text
  ) VALUES (p_agency_id, v_today, 'health_eve', now(), v_message_id, v_text)
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        updated_at = now();

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('health_eve prompt sent (msg_id=%s)', v_message_id));
END;
$function$;
