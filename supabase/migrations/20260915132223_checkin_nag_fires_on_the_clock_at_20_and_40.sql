-- Peter 2026-09-15: the nag fires at 20 past and 40 past the hour. On the clock.
-- It does not measure how long ago the message went out, and there is no grace
-- window. Removes the elapsed-minutes staging that made a 12:20 nag land at 12:25
-- because the message had posted four seconds after 12:00.
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_chat_id bigint;
  v_now timestamptz := now();
  v_ct timestamp := v_now AT TIME ZONE 'America/Chicago';
  v_today date := v_ct::date;
  v_min int := EXTRACT(MINUTE FROM v_ct)::int;
  v_hour_start timestamptz := date_trunc('hour', v_now);
  v_text text; v_response jsonb; v_message_id bigint; v_missing record;
  v_missing_tags text := ''; v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0;
  v_run record; v_stage text;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';

  -- Peter: no morning nags, ever.
  IF v_checkin_type = 'morning' THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: morning never nags');
  END IF;

  SELECT reminder_sent_at, tag_missing_at, tag_missing_message_id
  INTO v_run
  FROM public.team_checkin_runs
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  IF v_run.reminder_sent_at IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no check-in message went out today, nothing to tag');
  END IF;

  -- 20 past and 40 past nag the message sent at the top of this hour.
  -- The top of the next hour takes the nag down.
  IF v_min = 20 AND v_run.reminder_sent_at >= v_hour_start THEN
    v_stage := 'first';
  ELSIF v_min = 40 AND v_run.reminder_sent_at >= v_hour_start THEN
    v_stage := 'second';
  ELSIF v_min = 0 AND v_run.reminder_sent_at >= v_hour_start - INTERVAL '1 hour'
        AND v_run.reminder_sent_at < v_hour_start THEN
    v_stage := 'retire';
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag: nothing due at :%s', v_checkin_type, lpad(v_min::text, 2, '0')));
  END IF;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  IF v_stage = 'retire' THEN
    IF public.team_checkin_delete_message(
         p_agency_id, v_chat_id, v_checkin_type, 'nag', v_today) IS NOT NULL THEN
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('%s nag: retired', v_checkin_type));
    END IF;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag: nothing standing to retire', v_checkin_type));
  END IF;

  FOR v_missing IN
    SELECT m.team_id AS id, m.first_name
    FROM public.team_checkin_missing_acks(p_agency_id, v_today, v_checkin_type) m
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
  END LOOP;

  -- Everyone acknowledged. Take down any standing nag and go quiet.
  IF v_missing_count = 0 THEN
    PERFORM public.team_checkin_delete_message(
      p_agency_id, v_chat_id, v_checkin_type, 'nag', v_today);
    UPDATE public.team_checkin_runs
    SET tag_missing_at = v_now, updated_at = v_now
    WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag (:%s): silent (everyone acknowledged)',
        v_checkin_type, lpad(v_min::text, 2, '0')));
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
  SET tag_missing_at = v_now, tag_missing_message_id = v_message_id,
      tag_missing_team_ids = v_missing_ids, updated_at = v_now
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object('records_processed', v_missing_count,
    'output_summary', format('%s nag (%s, :%s): %s have not acknowledged',
      v_checkin_type, v_stage, lpad(v_min::text, 2, '0'), v_missing_count));
END;
$function$;
