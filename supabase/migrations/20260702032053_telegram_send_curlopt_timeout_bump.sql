-- Bump sync http extension timeouts on telegram_send_message and telegram_recover_checkins.
-- Root cause: extensions.http_post has a 5s default; group-chat send goes through the
-- /functions/v1/telegram edge fn which cold-starts occasionally. Matches the pattern
-- already in paper_newt_send_message. Body otherwise unchanged.

CREATE OR REPLACE FUNCTION public.telegram_send_message(
  p_chat_id bigint,
  p_text text,
  p_parse_mode text DEFAULT NULL::text,
  p_reply_to_message_id bigint DEFAULT NULL::bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $func$
DECLARE
  v_payload jsonb;
  v_response jsonb;
BEGIN
  v_payload := jsonb_build_object(
    'action', 'sendMessage',
    'chat_id', p_chat_id,
    'text', p_text
  );
  IF p_parse_mode IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('parse_mode', p_parse_mode);
  END IF;
  IF p_reply_to_message_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('reply_to_message_id', p_reply_to_message_id);
  END IF;

  -- Survive Telegram edge-fn cold starts (sync http extension defaults to 5s).
  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '5000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  SELECT (extensions.http_post(
    'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/telegram',
    v_payload::text,
    'application/json'
  )).content::jsonb INTO v_response;

  RETURN v_response;
END;
$func$;

CREATE OR REPLACE FUNCTION public.telegram_recover_checkins(
  p_checkin_date date,
  p_checkin_type text
) RETURNS jsonb
LANGUAGE plpgsql
AS $func$
DECLARE
  v_response jsonb;
BEGIN
  -- Same defensive timeout bump — recovery is best-effort but should not blow up on 5s cold start.
  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '5000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  v_response := (extensions.http_post(
    'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/telegram',
    json_build_object(
      'action', 'recoverCheckins',
      'checkin_date', p_checkin_date::text,
      'checkin_type', p_checkin_type
    )::text,
    'application/json'
  )).content::jsonb;
  RETURN v_response;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$func$;