-- Neither bot can message Alvi directly (she has never opened a chat with them), so the cart
-- goes to the Paper Newt management group chat, where she and Peter both see it.
DO $$
DECLARE v_def text; v_old text;
BEGIN
  v_def := pg_get_functiondef('public.prize_cart_send_for_approval()'::regprocedure);
  v_old := $o$  SELECT telegram_user_id INTO v_chat FROM public.team
  WHERE agency_id = v_agency AND nickname = 'Alvi' AND telegram_user_id IS NOT NULL LIMIT 1;
  IF v_chat IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no Telegram on file for Alvi'); END IF;$o$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'chat lookup not found'; END IF;
  v_def := replace(v_def, v_old, $n$  SELECT NULLIF(btrim(setting_value), '')::bigint INTO v_chat FROM public.settings
  WHERE agency_id = v_agency AND setting_key = 'paper_newt_management_group_chat_id';
  IF v_chat IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'paper_newt_management_group_chat_id not set'); END IF;$n$);
  v_old := 'v_res := public.telegram_send_message_v2(v_chat, v_text, ''pjsagency'', NULL, NULL);';
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'send call not found'; END IF;
  v_def := replace(v_def, v_old, 'v_res := public.paper_newt_send_message(v_chat, v_text, NULL, NULL);');
  v_def := replace(v_def, $o$'🛒 ' || v_label || ' prize cart is shopped and ready for you'$o$, $n$'🛒 Alvi, the ' || v_label || ' prize cart is shopped and ready for you'$n$);
  EXECUTE v_def;
END $$;
