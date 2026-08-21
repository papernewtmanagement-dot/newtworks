-- paper_newt_send_message: extend curl connect timeout + add transient-retry loop
-- Root cause (2026-06-20 18:00 CT): "Failed to connect to api.telegram.org port 443 
-- after 1002 ms" — single connect attempt with ~1s ceiling lost the Saturday nudge to a
-- network blip. Bot config fine (proven by 2026-06-19 success).
-- Fix: bump CURLOPT_CONNECTTIMEOUT_MS to 5000 + CURLOPT_TIMEOUT_MS to 10000, and retry
-- up to 3 times on exception or non-ok response with 1.5s backoff between attempts.

CREATE OR REPLACE FUNCTION public.paper_newt_send_message(
  p_chat_id bigint, 
  p_text text, 
  p_parse_mode text DEFAULT NULL::text, 
  p_reply_to_message_id bigint DEFAULT NULL::bigint
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_token       text;
  v_payload     jsonb;
  v_resp        jsonb;
  v_attempt     int := 0;
  v_max_attempts int := 3;
  v_last_err    text;
BEGIN
  SELECT setting_value INTO v_token FROM public.settings
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND setting_key = 'chatbot_bot_token';

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'chatbot_bot_token not set');
  END IF;

  v_payload := jsonb_build_object('chat_id', p_chat_id, 'text', p_text);
  IF p_parse_mode IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('parse_mode', p_parse_mode);
  END IF;
  IF p_reply_to_message_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('reply_to_message_id', p_reply_to_message_id);
  END IF;

  -- Extend curl timeouts above the ~1s default for connect, ~10s total.
  -- These persist for the session; harmless if reset is called elsewhere.
  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '5000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');

  WHILE v_attempt < v_max_attempts LOOP
    v_attempt := v_attempt + 1;
    BEGIN
      SELECT (extensions.http_post(
        'https://api.telegram.org/bot' || v_token || '/sendMessage',
        v_payload::text,
        'application/json'
      )).content::jsonb INTO v_resp;

      -- 2xx-equivalent: Telegram returns ok=true. Anything else is treated as transient
      -- on connect/timeout grounds but NOT on Telegram-side rejection (e.g. 403 Forbidden
      -- from "bot can't initiate conversation"). Telegram rejections come back with ok=false
      -- AND an error_code → return immediately, do not retry.
      IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
        RETURN v_resp;
      END IF;

      -- Has a Telegram error_code → genuine API rejection. Return without retry.
      IF v_resp IS NOT NULL AND v_resp ? 'error_code' THEN
        RETURN v_resp;
      END IF;

      -- Otherwise fall through to retry path
      v_last_err := 'unexpected response: ' || coalesce(v_resp::text, 'null');
    EXCEPTION WHEN OTHERS THEN
      v_last_err := 'exception: ' || SQLERRM;
    END;

    -- Don't sleep after the last attempt
    IF v_attempt < v_max_attempts THEN
      PERFORM pg_sleep(1.5);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', false,
    'error', v_last_err,
    'attempts', v_attempt
  );
END;
$function$;
