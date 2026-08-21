CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_input_config jsonb;
  v_checkin_type text;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_dow int;          -- 0=Sun .. 6=Sat
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_yesterday record;
  v_quote record;
BEGIN
  SELECT input_config INTO v_input_config
  FROM public.automation_recipes WHERE id = p_recipe_id;

  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF v_checkin_type NOT IN ('morning', 'midday', 'eod') THEN
    RAISE EXCEPTION 'Invalid checkin_type: %', v_checkin_type;
  END IF;

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time)
    );
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;

  SELECT setting_value::bigint INTO v_chat_id
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'telegram_team_group_chat_id not set';
  END IF;

  IF v_checkin_type = 'morning' THEN
    v_text := E'🌅 Morning meeting in 5 minutes!\n\n';

    SELECT quote_text, attribution, video_url INTO v_quote
    FROM public.health_quotes
    WHERE agency_id = p_agency_id AND is_active = true AND pool = 'morning_motivation'
    ORDER BY random() LIMIT 1;

    IF v_quote.quote_text IS NOT NULL THEN
      v_text := v_text || '"' || v_quote.quote_text || '"';
      IF v_quote.attribution IS NOT NULL THEN
        v_text := v_text || ' — ' || v_quote.attribution;
      END IF;
      IF v_quote.video_url IS NOT NULL THEN
        v_text := v_text || E'\n▶️ ' || v_quote.video_url;
      END IF;
      v_text := v_text || E'\n\n';
    END IF;

    SELECT * INTO v_yesterday
    FROM public.team_checkin_runs
    WHERE agency_id = p_agency_id
      AND checkin_type = 'eod'
      AND checkin_date < v_today
      AND total_quotes_week IS NOT NULL
    ORDER BY checkin_date DESC LIMIT 1;

    IF FOUND THEN
      v_text := v_text || format('EOD numbers from %s: team totals were %s/%s%s',
        to_char(v_yesterday.checkin_date, 'Mon DD'),
        COALESCE(v_yesterday.total_quotes_week::text, '0'),
        COALESCE(v_yesterday.total_sales_points_quarter::text, '0'),
        E'\n\n');
    ELSE
      v_text := v_text || E'(No prior EOD numbers on record)\n\n';
    END IF;
  ELSIF v_checkin_type = 'midday' THEN
    v_text := E'☀️ Midday checkin!\n\n';
  ELSE
    v_text := E'🌙 EOD checkin!\n\n';
  END IF;

  v_text := v_text
    || E'Reply with your numbers — quotes this week / sales points this quarter:\n'
    || E'   12/45\n\n'
    || E'Covering for someone? Tag their name:\n'
    || E'   Cassandra 5/28';

  -- EOD wrapup nudge
  IF v_checkin_type = 'eod' THEN
    v_text := v_text || E'\n\nThen begin your daily wrapup.';
  END IF;

  -- Morning movement reminder
  IF v_checkin_type = 'morning' THEN
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'🏃 Move throughout the day. Get those steps in, take the stairs, '
      || E'and hit your exercise goal. We''ll check on the health goals at 7 PM.';
  END IF;

  -- v5: Friday EOD weekly wrapup + CPR email reminder
  IF v_checkin_type = 'eod' AND v_dow = 5 THEN
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'📝 Friday Weekly Wrapup\n\n'
      || E'Before you log off, drop your answers in this chat:\n\n'
      || E'1️⃣ Greatest personal obstacle from this week?\n'
      || E'2️⃣ One practical goal for next week to get a 1% gain in your sales points?\n'
      || E'3️⃣ One way we can improve overall office efficiency?\n'
      || E'4️⃣ Brags for each teammate?\n\n'
      || E'━━━━━━━━━━━━━━━━━━━\n'
      || E'📬 Also: reply to Peter''s weekly CPR email if you haven''t yet.';
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;

  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type,
    reminder_sent_at, reminder_message_id, reminder_text
  ) VALUES (
    p_agency_id, v_today, v_checkin_type,
    now(), v_message_id, v_text
  )
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        updated_at = now();

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s reminder sent (msg_id=%s, dow=%s)', v_checkin_type, v_message_id, v_dow)
  );
END;
$function$;
