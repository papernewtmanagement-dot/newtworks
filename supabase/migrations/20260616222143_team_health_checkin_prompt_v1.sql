CREATE OR REPLACE FUNCTION public.team_health_checkin_prompt(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_input_config jsonb;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_quote record;
BEGIN
  SELECT input_config INTO v_input_config
  FROM public.automation_recipes WHERE id = p_recipe_id;

  v_local_time := v_input_config->>'local_time';

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time)
    );
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  SELECT setting_value::bigint INTO v_chat_id
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'telegram_team_group_chat_id not set';
  END IF;

  -- Pick a random active quote
  SELECT quote_text, attribution INTO v_quote
  FROM public.health_quotes
  WHERE agency_id = p_agency_id AND is_active = true
  ORDER BY random()
  LIMIT 1;

  v_text := E'💪 Health goal checkin — where is everyone at?\n\n';

  IF v_quote.quote_text IS NOT NULL THEN
    v_text := v_text || '"' || v_quote.quote_text || '"';
    IF v_quote.attribution IS NOT NULL THEN
      v_text := v_text || ' — ' || v_quote.attribution;
    END IF;
    v_text := v_text || E'\n\n';
  END IF;

  v_text := v_text
    || E'Did you hit your exercise goal today? The target is 5 days a week.\n\n'
    || E'Reply yes / no — or tell us where you''re at for the week:\n'
    || E'   yes\n'
    || E'   3/5\n\n'
    || E'Covering for someone? Tag their name:\n'
    || E'   Cassandra yes\n'
    || E'   Thomas 4/5';

  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;

  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type,
    reminder_sent_at, reminder_message_id, reminder_text
  ) VALUES (
    p_agency_id, v_today, 'health_eve',
    now(), v_message_id, v_text
  )
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        updated_at = now();

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('health_eve prompt sent (msg_id=%s)', v_message_id)
  );
END;
$function$;
