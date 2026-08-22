-- =========================================================================
-- DRY consolidation: delegate duplicate sender functions to their canonicals
-- =========================================================================
-- 1) time_off_send_email was a byte-identical copy of composio_send_email
--    (only one word differed in an error message). It now delegates.
-- 2) telegram_send_message and paper_newt_send_message were strict subsets of
--    telegram_send_message_v2 (which selects the bot token by name). Both now
--    delegate. Known benign behavior deltas from delegation:
--      - v2 appends a 'bot_used' key to responses (callers read ->>'ok' and
--        'error_code' only; extra key is harmless)
--      - paper_newt path total HTTP timeout widens 10s -> 20s (v2's setting)
--    Entry-point privileges preserved: paper_newt_send_message keeps
--    SECURITY DEFINER (inner call inherits owner), telegram_send_message
--    stays invoker, exactly as before.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.time_off_send_email(p_agency_id uuid, p_to text, p_subject text, p_html_body text)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT public.composio_send_email(p_agency_id, p_to, p_subject, p_html_body);
$$;

CREATE OR REPLACE FUNCTION public.telegram_send_message(p_chat_id bigint, p_text text, p_parse_mode text DEFAULT NULL::text, p_reply_to_message_id bigint DEFAULT NULL::bigint)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT public.telegram_send_message_v2(p_chat_id, p_text, 'pjsagency', p_parse_mode, p_reply_to_message_id);
$$;

CREATE OR REPLACE FUNCTION public.paper_newt_send_message(p_chat_id bigint, p_text text, p_parse_mode text DEFAULT NULL::text, p_reply_to_message_id bigint DEFAULT NULL::bigint)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
  SELECT public.telegram_send_message_v2(p_chat_id, p_text, 'paper_newt', p_parse_mode, p_reply_to_message_id);
$$;
