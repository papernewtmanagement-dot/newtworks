-- The check-in message posts a few seconds AFTER the top of the hour, because
-- the dispatcher has to build and send it. At the :20 tick only 19 minutes and
-- 56 seconds had passed, so the +20 nag was not due yet and fell through to the
-- :25 tick. On 2026-09-15 the midday nag went out at 12:25 instead of 12:20.
-- A 90-second grace is added to the elapsed-time test so a tick that is meant
-- to be the +20 (or +40, or +60) always counts as due. The minute number shown
-- in the run log stays the real one.
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_chat_id bigint;
  v_today date; v_text text; v_response jsonb; v_message_id bigint; v_missing record;
  v_missing_tags text := ''; v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0;
  v_run record; v_elapsed numeric; v_shown numeric; v_stage text;
  -- The send takes a few seconds, so a tick can land just under its mark.
  c_grace constant interval := INTERVAL '90 seconds';
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';

  -- Peter: no morning nags, ever.
  IF v_checkin_type = 'morning' THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: morning never nags');
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  SELECT reminder_sent_at, tag_missing_at, tag_missing_message_id
  INTO v_run
  FROM public.team_checkin_runs
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  IF v_run.reminder_sent_at IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no check-in message went out today, nothing to tag');
  END IF;

  v_elapsed := EXTRACT(EPOCH FROM (now() - v_run.reminder_sent_at + c_grace)) / 60.0;
  v_shown   := EXTRACT(EPOCH FROM (now() - v_run.reminder_sent_at)) / 60.0;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  IF v_elapsed >= 60 THEN
    v_stage := 'retire';
  ELSIF v_elapsed >= 40
        AND COALESCE(v_run.tag_missing_at, v_run.reminder_sent_at)
            < v_run.reminder_sent_at + INTERVAL '40 minutes' - c_grace THEN
    v_stage := 'second';
  ELSIF v_elapsed >= 20 AND v_elapsed < 40 AND v_run.tag_missing_at IS NULL THEN
    v_stage := 'first';
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag: nothing due at +%s min',
        v_checkin_type, round(v_shown)));
  END IF;

  -- Take the standing nag down and post nothing.
  IF v_stage = 'retire' THEN
    IF public.team_checkin_delete_message(
         p_agency_id, v_chat_id, v_checkin_type, 'nag', v_today) IS NOT NULL THEN
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('%s nag: retired at +%s min',
          v_checkin_type, round(v_shown)));
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
    SET tag_missing_at = now(), updated_at = now()
    WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag (+%s min): silent (everyone acknowledged)',
        v_checkin_type, round(v_shown)));
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
    'output_summary', format('%s nag (%s, +%s min): %s have not acknowledged',
      v_checkin_type, v_stage, round(v_shown), v_missing_count));
END;
$function$;
