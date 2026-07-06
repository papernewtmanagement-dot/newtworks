-- Follow-up: leslie_monthly_goals_send now sends via paper_newt_bot, so it
-- must consult is_excluded_paper_newt_bot (not legacy is_excluded, which governs pjsagencybot).
CREATE OR REPLACE FUNCTION public.leslie_monthly_goals_send(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions'
AS $fn$
DECLARE
  v_group_chat_id BIGINT;
  v_review_month DATE;
  v_month_label TEXT;
  v_marie_user_id BIGINT;
  v_mention TEXT;
  v_message TEXT;
  v_resp JSONB;
  v_row_id UUID;
  v_message_id BIGINT;
  v_ok BOOLEAN;
BEGIN
  SELECT setting_value::bigint INTO v_group_chat_id
  FROM public.settings
  WHERE agency_id = p_agency_id
    AND setting_key = 'paper_newt_management_group_chat_id';

  IF v_group_chat_id IS NULL THEN
    RAISE EXCEPTION 'paper_newt_management_group_chat_id not set';
  END IF;

  v_review_month := date_trunc('month', (NOW() AT TIME ZONE 'America/Chicago' - INTERVAL '1 day'))::date;
  v_month_label := to_char(v_review_month, 'FMMonth YYYY');

  SELECT ttm.telegram_user_id INTO v_marie_user_id
  FROM public.team_telegram_map ttm
  WHERE ttm.agency_id = p_agency_id
    AND ttm.team_id = 'd7431075-d29f-4833-9503-430945894b04'
    AND COALESCE(ttm.is_excluded_paper_newt_bot, false) = false
  LIMIT 1;

  IF v_marie_user_id IS NOT NULL THEN
    v_mention := format('<a href="tg://user?id=%s">Alvi</a>', v_marie_user_id);
  ELSE
    v_mention := 'Alvi';
  END IF;

  v_message := format(
    E'%s — did Leslie hit her goals in %s? Reply here.',
    v_mention, v_month_label
  );

  INSERT INTO public.leslie_monthly_checkin (agency_id, review_month)
  VALUES (p_agency_id, v_review_month)
  ON CONFLICT (agency_id, review_month) DO NOTHING
  RETURNING id INTO v_row_id;

  IF v_row_id IS NULL THEN
    SELECT id INTO v_row_id
    FROM public.leslie_monthly_checkin
    WHERE agency_id = p_agency_id AND review_month = v_review_month;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.leslie_monthly_checkin
    WHERE id = v_row_id AND sent_at IS NOT NULL AND marie_reply_text IS NOT NULL
  ) THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Already complete for %s — skipped', v_month_label)
    );
  END IF;

  v_resp := public.paper_newt_send_message(v_group_chat_id, v_message, 'HTML', NULL);

  v_ok := COALESCE((v_resp->>'ok')::boolean, false);
  v_message_id := NULLIF((v_resp #>> '{result,message_id}'), '')::bigint;

  UPDATE public.leslie_monthly_checkin
  SET sent_at = NOW(),
      sent_ok = v_ok,
      sent_response = v_resp,
      sent_message_id = v_message_id,
      updated_at = NOW()
  WHERE id = v_row_id;

  IF NOT v_ok THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Send failed for %s: %s', v_month_label, v_resp->>'error')
    );
  END IF;

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('Sent Leslie goals check-in for %s (msg_id %s)', v_month_label, v_message_id)
  );
END;
$fn$;
