-- Peter 2026-09-10: no message may ever have more than one blank line in a row.
-- The EOD results had two blank lines before the deposit reminder because the
-- status block ends with a newline and the deposit line was added with two more.
-- Fixed at the one place every Telegram message passes through, so every
-- message is covered, not just this one.

CREATE OR REPLACE FUNCTION public.tidy_message_text(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN p_text IS NULL THEN NULL ELSE
    rtrim(
      regexp_replace(
        regexp_replace(p_text, '\n[ \t\r]*\n([ \t\r]*\n)+', E'\n\n', 'g'),
        '^([ \t\r]*\n)+', ''),
      E' \t\r\n')
  END;
$$;

COMMENT ON FUNCTION public.tidy_message_text(text) IS
  'Collapses any run of blank lines to one blank line and trims blank lines at the start and end. Applied to every Telegram send and edit. Peter rule 2026-09-10.';

CREATE OR REPLACE FUNCTION public.telegram_send_message_v2(p_chat_id bigint, p_text text, p_bot text DEFAULT 'pjsagency'::text, p_parse_mode text DEFAULT NULL::text, p_reply_to_message_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_token_key   text;
  v_token       text;
  v_payload     jsonb;
  v_resp        jsonb;
  v_attempt     int := 0;
  v_max_attempts int := 3;
  v_last_err    text;
BEGIN
  v_token_key := CASE p_bot
    WHEN 'paper_newt' THEN 'chatbot_bot_token'
    WHEN 'pjsagency'  THEN 'telegram_bot_token'
    ELSE 'telegram_bot_token'
  END;

  SELECT setting_value INTO v_token FROM public.settings
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND setting_key = v_token_key;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', format('%s not set', v_token_key), 'bot_requested', p_bot);
  END IF;

  -- One blank line max between lines, every message (Peter 2026-09-10).
  v_payload := jsonb_build_object('chat_id', p_chat_id, 'text', public.tidy_message_text(p_text));
  IF p_parse_mode IS NOT NULL THEN v_payload := v_payload || jsonb_build_object('parse_mode', p_parse_mode); END IF;
  IF p_reply_to_message_id IS NOT NULL THEN v_payload := v_payload || jsonb_build_object('reply_to_message_id', p_reply_to_message_id); END IF;

  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '5000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  WHILE v_attempt < v_max_attempts LOOP
    v_attempt := v_attempt + 1;
    BEGIN
      SELECT (extensions.http_post(
        'https://api.telegram.org/bot' || v_token || '/sendMessage',
        v_payload::text,
        'application/json'
      )).content::jsonb INTO v_resp;

      IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
        RETURN v_resp || jsonb_build_object('bot_used', p_bot);
      END IF;
      IF v_resp IS NOT NULL AND v_resp ? 'error_code' THEN
        RETURN v_resp || jsonb_build_object('bot_used', p_bot);
      END IF;
      v_last_err := 'unexpected response: ' || coalesce(v_resp::text, 'null');
    EXCEPTION WHEN OTHERS THEN
      v_last_err := 'exception: ' || SQLERRM;
    END;
    IF v_attempt < v_max_attempts THEN PERFORM pg_sleep(1.5); END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', false, 'error', v_last_err, 'attempts', v_attempt, 'bot_used', p_bot);
END;
$function$;

CREATE OR REPLACE FUNCTION public.telegram_api_call(p_method text, p_payload jsonb, p_bot text DEFAULT 'pjsagency'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_token_key text;
  v_token text;
  v_resp jsonb;
  v_attempt int := 0;
  v_max_attempts int := 3;
  v_last_err text;
  v_payload jsonb := p_payload;
BEGIN
  v_token_key := CASE p_bot
    WHEN 'paper_newt' THEN 'chatbot_bot_token'
    WHEN 'pjsagency'  THEN 'telegram_bot_token'
    ELSE 'telegram_bot_token'
  END;

  SELECT setting_value INTO v_token FROM public.settings
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND setting_key = v_token_key;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', format('%s not set', v_token_key));
  END IF;

  -- One blank line max between lines on edits, captions, and any direct send (Peter 2026-09-10).
  IF jsonb_typeof(v_payload->'text') = 'string' THEN
    v_payload := v_payload || jsonb_build_object('text', public.tidy_message_text(v_payload->>'text'));
  END IF;
  IF jsonb_typeof(v_payload->'caption') = 'string' THEN
    v_payload := v_payload || jsonb_build_object('caption', public.tidy_message_text(v_payload->>'caption'));
  END IF;

  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '5000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  WHILE v_attempt < v_max_attempts LOOP
    v_attempt := v_attempt + 1;
    BEGIN
      SELECT (extensions.http_post(
        'https://api.telegram.org/bot' || v_token || '/' || p_method,
        v_payload::text,
        'application/json'
      )).content::jsonb INTO v_resp;

      IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
        RETURN v_resp;
      END IF;
      IF v_resp IS NOT NULL AND v_resp ? 'error_code' THEN
        RETURN v_resp;
      END IF;
      v_last_err := 'unexpected response: ' || coalesce(v_resp::text, 'null');
    EXCEPTION WHEN OTHERS THEN
      v_last_err := 'exception: ' || SQLERRM;
    END;
    IF v_attempt < v_max_attempts THEN PERFORM pg_sleep(1.5); END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', false, 'error', v_last_err, 'attempts', v_attempt);
END;
$function$;