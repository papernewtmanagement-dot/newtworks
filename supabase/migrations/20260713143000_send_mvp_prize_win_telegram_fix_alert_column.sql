-- Fix: send_mvp_prize_win_telegram inserted into alerts using `description`
-- but the actual column is `message`. Silent throw if ever hit an error branch.
-- Also adds alert_type + related_id (prize_cart_id) for proper alert routing.

CREATE OR REPLACE FUNCTION public.send_mvp_prize_win_telegram(p_agency_id uuid, p_mvp_team_id uuid, p_prize_cart_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_group_chat_id bigint;
  v_marie_user_id bigint;
  v_mvp_name      text;
  v_prize_desc    text;
  v_prize_url     text;
  v_html          text;
  v_marie_tag     text;
  v_resp          jsonb;
BEGIN
  SELECT setting_value::bigint INTO v_group_chat_id
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'paper_newt_management_group_chat_id';

  SELECT setting_value::bigint INTO v_marie_user_id
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'marie_telegram_user_id';

  SELECT COALESCE(nickname, first_name) INTO v_mvp_name
  FROM public.team WHERE id = p_mvp_team_id;

  SELECT prize_description, prize_url INTO v_prize_desc, v_prize_url
  FROM public.prize_cart WHERE id = p_prize_cart_id;

  IF v_group_chat_id IS NULL OR v_mvp_name IS NULL OR v_prize_desc IS NULL THEN
    INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
    VALUES (p_agency_id, 'system', 'mvp_prize_draw', 'high',
            'MVP prize Telegram send: missing config',
            format('group_chat_id=%s mvp_name=%s prize_desc=%s',
                   v_group_chat_id, v_mvp_name, v_prize_desc),
            p_prize_cart_id,
            false);
    RETURN jsonb_build_object('ok', false, 'error', 'missing config');
  END IF;

  v_marie_tag := CASE
    WHEN v_marie_user_id IS NOT NULL
    THEN '<a href="tg://user?id=' || v_marie_user_id::text || '">Marie</a>'
    ELSE 'Marie'
  END;

  v_html := '🏆 <b>' || v_mvp_name || '</b> won the MVP Prize Cart draw!' || chr(10) || chr(10)
         || 'Prize: <a href="' || COALESCE(v_prize_url, '') || '">' || v_prize_desc || '</a>' || chr(10) || chr(10)
         || v_marie_tag || ' — please order and coordinate delivery.';

  BEGIN
    v_resp := public.paper_newt_send_message(v_group_chat_id, v_html, 'HTML', NULL);
    IF (v_resp->>'ok')::boolean IS DISTINCT FROM true THEN
      INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
      VALUES (p_agency_id, 'system', 'mvp_prize_draw', 'high',
              'MVP prize Telegram send failed',
              format('Prize=%s Winner=%s Response=%s', v_prize_desc, v_mvp_name, v_resp::text),
              p_prize_cart_id,
              false);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_resp := jsonb_build_object('ok', false, 'error', SQLERRM);
    INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
    VALUES (p_agency_id, 'system', 'mvp_prize_draw', 'high',
            'MVP prize Telegram send exception',
            format('Prize=%s Winner=%s Error=%s', v_prize_desc, v_mvp_name, SQLERRM),
            p_prize_cart_id,
            false);
  END;

  RETURN v_resp;
END;
$function$;
