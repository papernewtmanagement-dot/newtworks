-- Nags at +20 and +40 minutes after the reminder, midday and end of day only.
-- Never in the morning. The +40 deletes the +20. At +60 the last nag is deleted
-- and nothing posts. One message slot: team_checkin_runs.tag_missing_message_id,
-- delete then repost, never edit in place (an edit fires no notification).
-- Timing is measured from reminder_sent_at, so it is immune to daylight saving
-- and needs no local-time guard.
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
      'output_summary', 'Skipped: no reminder went out today, nothing to tag');
  END IF;

  v_elapsed := EXTRACT(EPOCH FROM (now() - v_run.reminder_sent_at)) / 60.0;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  -- Once the summary has gone out the reminder is gone too, so a nag pointing at
  -- it is meaningless. Clear any survivor and stop.
  IF v_run.compile_results_at IS NOT NULL THEN
    v_stage := 'after_summary';
  ELSIF v_elapsed >= 60 THEN
    v_stage := 'retire';
  ELSIF v_elapsed >= 40 AND v_elapsed < 50
        AND COALESCE(v_run.tag_missing_at, v_run.reminder_sent_at)
            < v_run.reminder_sent_at + INTERVAL '40 minutes' THEN
    v_stage := 'second';
  ELSIF v_elapsed >= 20 AND v_elapsed < 40 AND v_run.tag_missing_at IS NULL THEN
    v_stage := 'first';
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s tag-missing: nothing due at +%s min',
        v_checkin_type, round(v_elapsed)));
  END IF;

  -- Retire the standing nag and post nothing.
  IF v_stage IN ('retire', 'after_summary') THEN
    IF v_run.tag_missing_message_id IS NOT NULL THEN
      PERFORM public.telegram_delete_message(v_chat_id, v_run.tag_missing_message_id);
      UPDATE public.team_checkin_runs
      SET tag_missing_message_id = NULL, updated_at = now()
      WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('%s tag-missing: nag retired at +%s min',
          v_checkin_type, round(v_elapsed)));
    END IF;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s tag-missing: nothing standing to retire', v_checkin_type));
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
    IF v_run.tag_missing_message_id IS NOT NULL THEN
      PERFORM public.telegram_delete_message(v_chat_id, v_run.tag_missing_message_id);
    END IF;
    UPDATE public.team_checkin_runs
    SET tag_missing_at = now(), tag_missing_message_id = NULL, updated_at = now()
    WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s tag-missing (+%s min): silent (everyone reacted)',
        v_checkin_type, round(v_elapsed)));
  END IF;

  -- Delete then repost. The second nag replaces the first in the same slot.
  IF v_run.tag_missing_message_id IS NOT NULL THEN
    PERFORM public.telegram_delete_message(v_chat_id, v_run.tag_missing_message_id);
  END IF;

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
    'output_summary', format('%s tag-missing (%s, +%s min): %s have not reacted',
      v_checkin_type, v_stage, round(v_elapsed), v_missing_count));
END;
$function$;