-- v12: Friday EOD wrapup now asks for the main personal obstacle from this week.
-- Inserted as item #2 so the list reads past-week reflection → next-week goals.

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
  v_dow int;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_quote record;
  v_per_person text;
  v_last_eod_date date;
  v_total_q numeric;
  v_total_s numeric;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF v_checkin_type NOT IN ('morning', 'midday', 'eod') THEN
    RAISE EXCEPTION 'Invalid checkin_type: %', v_checkin_type;
  END IF;

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';
  IF v_chat_id IS NULL THEN RAISE EXCEPTION 'telegram_team_group_chat_id not set'; END IF;

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

    SELECT max(checkin_date) INTO v_last_eod_date
    FROM public.team_checkins
    WHERE agency_id = p_agency_id AND checkin_type = 'eod' AND checkin_date < v_today;

    IF v_last_eod_date IS NOT NULL THEN
      SELECT
        string_agg(
          format('• %s: %s/%s',
            COALESCE(NULLIF(t.nickname, ''), t.first_name),
            COALESCE(tc.quotes_week::text, '—'),
            COALESCE(tc.sales_points_quarter::text, '—')),
          E'\n' ORDER BY t.first_name),
        COALESCE(SUM(tc.quotes_week), 0),
        COALESCE(SUM(tc.sales_points_quarter), 0)
      INTO v_per_person, v_total_q, v_total_s
      FROM public.team_checkins tc
      JOIN public.team t ON t.id = tc.team_id
      WHERE tc.agency_id = p_agency_id
        AND tc.checkin_date = v_last_eod_date
        AND tc.checkin_type = 'eod';

      v_text := v_text || format('📊 Last EOD (%s):', to_char(v_last_eod_date, 'Mon DD')) || E'\n';
      IF v_per_person IS NOT NULL THEN
        v_text := v_text || v_per_person || E'\n';
      END IF;
      v_text := v_text || format('Team total: %s/%s', v_total_q::text, v_total_s::text);
    ELSE
      v_text := v_text || E'(No prior EOD numbers on record yet.)';
    END IF;

    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'🏃 Move throughout the day. Get those steps in, take the stairs, '
      || E'and hit your exercise goal. We''ll check on the health goals at 7 PM.';

  ELSIF v_checkin_type = 'midday' THEN
    v_text := E'☀️ Midday checkin!\n\n'
      || E'Quotes discussed this week / Sales points this quarter\n\n'
      || E'If someone''s busy, answer for them.';
  ELSE
    v_text := E'🌙 Daily Wrapup and EOD checkin!\n\n'
      || E'Quotes discussed this week / Sales points this quarter\n\n'
      || E'If someone''s busy, answer for them.';
  END IF;

  -- Friday EOD wrapup tail (v12: added personal obstacle as item #2)
  IF v_checkin_type = 'eod' AND v_dow = 5 THEN
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'📝 Weekly wrapup — email to paper.newt.management@gmail.com:\n\n'
      || E'1. Attach your FIT Scorecard from this week.\n'
      || E'2. Main personal obstacle from this week.\n'
      || E'3. One goal for next week — 1% gain in sales points?\n'
      || E'4. One way to improve office efficiency?\n'
      || E'5. Brags for each teammate.\n\n'
      || E'━━━━━━━━━━━━━━━━━━━\n'
      || E'📬 And reply to Peter''s CPR email if you haven''t.';
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

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('%s reminder sent (msg_id=%s, dow=%s)', v_checkin_type, v_message_id, v_dow));
END;
$function$;
