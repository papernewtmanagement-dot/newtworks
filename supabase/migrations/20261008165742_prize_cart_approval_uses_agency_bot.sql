-- Alvi has never started a chat with the Paper Newt bot, so Telegram refuses it ("bot can't initiate
-- conversation"). Her other alerts reach her; send the prize cart through the agency bot instead.
DO $$
DECLARE v_def text; v_old text;
BEGIN
  v_def := pg_get_functiondef('public.prize_cart_send_for_approval()'::regprocedure);
  v_old := 'v_res := public.paper_newt_send_message(v_chat, v_text, NULL, NULL);';
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'send call not found'; END IF;
  EXECUTE replace(v_def, v_old, 'v_res := public.telegram_send_message_v2(v_chat, v_text, ''pjsagency'', NULL, NULL);');
END $$;
