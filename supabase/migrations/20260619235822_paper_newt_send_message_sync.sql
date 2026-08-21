CREATE OR REPLACE FUNCTION public.paper_newt_send_message(
  p_chat_id bigint,
  p_text text,
  p_parse_mode text DEFAULT NULL,
  p_reply_to_message_id bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $func$
DECLARE
  v_token   text;
  v_payload jsonb;
  v_resp    jsonb;
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

  SELECT (extensions.http_post(
    'https://api.telegram.org/bot' || v_token || '/sendMessage',
    v_payload::text,
    'application/json'
  )).content::jsonb INTO v_resp;

  RETURN v_resp;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'exception: ' || SQLERRM);
END;
$func$;
