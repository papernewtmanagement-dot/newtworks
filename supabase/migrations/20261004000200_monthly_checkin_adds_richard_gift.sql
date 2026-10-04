-- 2026-10-04 Peter: Richard's $700 is added automatically each month and Alvi's monthly check-in says so.
-- Plus: household credits -> 8600, 8600 not tithed, office property tax account 6711 (applied separately, see 20261004000100).
CREATE OR REPLACE FUNCTION public.leslie_monthly_goals_send(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_group_chat_id BIGINT;
  v_review_month DATE;
  v_month_label TEXT;
  v_marie_user_id BIGINT;
  v_mention TEXT;
  v_message TEXT;
  v_sales_count INT;
  v_sales_list TEXT;
  v_sales_line TEXT;
  v_richard_recipe UUID;
  v_richard JSONB;
  v_richard_line TEXT := '';
  v_resp JSONB;
  v_row_id UUID;
  v_message_id BIGINT;
  v_ok BOOLEAN;
BEGIN
  SELECT setting_value::bigint INTO v_group_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'paper_newt_management_group_chat_id';
  IF v_group_chat_id IS NULL THEN RAISE EXCEPTION 'paper_newt_management_group_chat_id not set'; END IF;

  v_review_month := date_trunc('month', (NOW() AT TIME ZONE 'America/Chicago' - INTERVAL '1 day'))::date;
  v_month_label := to_char(v_review_month, 'FMMonth YYYY');

  -- Richard's monthly gift (Peter 2026-10-04): booked here so Alvi gets one message, not two.
  -- Paused by turning off the "Richard Monthly Gift" recipe on the Automations page.
  SELECT id INTO v_richard_recipe FROM public.automation_recipes
  WHERE agency_id = p_agency_id AND internal_handler = 'richard_monthly_gift_book' LIMIT 1;
  IF v_richard_recipe IS NOT NULL THEN
    v_richard := public.richard_monthly_gift_book(p_agency_id, v_richard_recipe);
    IF COALESCE(v_richard->>'reason', '') <> 'paused' THEN
      v_richard_line := format(E'\n\n3. Richard''s $700 gift for %s was added automatically. If it didn''t come, delete it in Financials (Non-taxable Income, the Richard row).', v_month_label);
    END IF;
  END IF;

  SELECT t.telegram_user_id INTO v_marie_user_id FROM public.team t
  WHERE t.agency_id = p_agency_id AND t.id = 'd7431075-d29f-4833-9503-430945894b04'
    AND COALESCE(t.is_excluded_paper_newt_bot, false) = false LIMIT 1;

  IF v_marie_user_id IS NOT NULL THEN
    v_mention := format('<a href="tg://user?id=%s">Alvi</a>', v_marie_user_id);
  ELSE v_mention := 'Alvi'; END IF;

  -- PaperNewt print sales already booked for the month (4300, from PayPal invoices)
  SELECT count(*),
         string_agg(format('• %s — %s', to_char(l.entry_date, 'Mon FMDD'),
                    regexp_replace(l.description, '^PayPal print sale — (invoice #\d+ — )?', '')), E'\n' ORDER BY l.entry_date)
    INTO v_sales_count, v_sales_list
  FROM public.ledger l
  JOIN public.chart_of_accounts c ON c.id = l.account_id
  WHERE l.agency_id = p_agency_id
    AND c.account_code = '4300'
    AND c.business_entity_id = 'b1111111-1111-1111-1111-111111111111'
    AND l.source = 'paypal_print_sales'
    AND l.entry_date >= v_review_month
    AND l.entry_date < (v_review_month + INTERVAL '1 month');

  IF v_sales_count > 0 THEN
    v_sales_line := format(E'Newtworks has %s print sale%s for %s:\n%s\nAny other sale? Forward its PayPal "paid for your invoice" email to paper.newt.management@gmail.com.',
                           v_sales_count, CASE WHEN v_sales_count = 1 THEN '' ELSE 's' END, v_month_label, v_sales_list);
  ELSE
    v_sales_line := format('Newtworks has no print sales for %s. If there were any, forward each PayPal "paid for your invoice" email to paper.newt.management@gmail.com.', v_month_label);
  END IF;

  v_message := format(E'%s — monthly checks for %s:\n\n1. Did Leslie hit her goals in %s?\n\n2. PaperNewt print sales. %s%s\n\nReply here.',
                      v_mention, v_month_label, v_month_label, v_sales_line, v_richard_line);

  INSERT INTO public.leslie_monthly_checkin (agency_id, review_month)
  VALUES (p_agency_id, v_review_month)
  ON CONFLICT (agency_id, review_month) DO NOTHING RETURNING id INTO v_row_id;

  IF v_row_id IS NULL THEN
    SELECT id INTO v_row_id FROM public.leslie_monthly_checkin
    WHERE agency_id = p_agency_id AND review_month = v_review_month;
  END IF;

  IF EXISTS (SELECT 1 FROM public.leslie_monthly_checkin
    WHERE id = v_row_id AND sent_at IS NOT NULL AND marie_reply_text IS NOT NULL) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Already complete for %s — skipped', v_month_label));
  END IF;

  v_resp := public.paper_newt_send_message(v_group_chat_id, v_message, 'HTML', NULL);
  v_ok := COALESCE((v_resp->>'ok')::boolean, false);
  v_message_id := NULLIF((v_resp #>> '{result,message_id}'), '')::bigint;

  UPDATE public.leslie_monthly_checkin
  SET sent_at = NOW(), sent_ok = v_ok, sent_response = v_resp,
      sent_message_id = v_message_id, updated_at = NOW()
  WHERE id = v_row_id;

  IF NOT v_ok THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Send failed for %s: %s', v_month_label, v_resp->>'error'));
  END IF;
  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('Sent Leslie goals + print sales check-in for %s (msg_id %s)', v_month_label, v_message_id));
END;
$function$;

