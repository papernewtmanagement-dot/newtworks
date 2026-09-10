-- Same shape as telegram_send_message_v2: token from settings, curl timeouts,
-- three attempts. Needed so the check-in compile can rewrite the reminder
-- message in place and clear the tag-missing message instead of stacking new
-- bubbles in the team channel.
CREATE OR REPLACE FUNCTION public.telegram_api_call(p_method text, p_payload jsonb, p_bot text DEFAULT 'pjsagency')
 RETURNS jsonb
 LANGUAGE plpgsql
AS $fn$
DECLARE
  v_token_key text;
  v_token text;
  v_resp jsonb;
  v_attempt int := 0;
  v_max_attempts int := 3;
  v_last_err text;
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

  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '5000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  WHILE v_attempt < v_max_attempts LOOP
    v_attempt := v_attempt + 1;
    BEGIN
      SELECT (extensions.http_post(
        'https://api.telegram.org/bot' || v_token || '/' || p_method,
        p_payload::text,
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
$fn$;

CREATE OR REPLACE FUNCTION public.telegram_edit_message_text(
  p_chat_id bigint, p_message_id bigint, p_text text, p_parse_mode text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE sql
AS $fn$
  SELECT public.telegram_api_call('editMessageText',
    jsonb_build_object('chat_id', p_chat_id, 'message_id', p_message_id, 'text', p_text)
    || CASE WHEN p_parse_mode IS NULL THEN '{}'::jsonb
            ELSE jsonb_build_object('parse_mode', p_parse_mode) END);
$fn$;

CREATE OR REPLACE FUNCTION public.telegram_delete_message(p_chat_id bigint, p_message_id bigint)
 RETURNS jsonb
 LANGUAGE sql
AS $fn$
  SELECT public.telegram_api_call('deleteMessage',
    jsonb_build_object('chat_id', p_chat_id, 'message_id', p_message_id));
$fn$;
