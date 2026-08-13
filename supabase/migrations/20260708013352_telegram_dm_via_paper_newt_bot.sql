-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 01:33:52 UTC (ledger name: telegram_dm_via_paper_newt_bot) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708013352.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- Add a bot-selector variant of telegram_send_message.
-- 'paper_newt' → @paper_newt_bot (personal DMs to Peter)
-- 'pjsagency'  → @pjsagencybot (team group chat, default for backward compat)
CREATE OR REPLACE FUNCTION public.telegram_send_message_v2(
  p_chat_id bigint,
  p_text text,
  p_bot text DEFAULT 'pjsagency',
  p_parse_mode text DEFAULT NULL,
  p_reply_to_message_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_token_key   text;
  v_token       text;
  v_payload     jsonb;
  v_resp        jsonb;
  v_attempt     int := 0;
  v_max_attempts int := 3;
  v_last_err    text;
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
    RETURN jsonb_build_object('ok', false, 'error', format('%s not set', v_token_key), 'bot_requested', p_bot);
  END IF;

  v_payload := jsonb_build_object('chat_id', p_chat_id, 'text', p_text);
  IF p_parse_mode IS NOT NULL THEN v_payload := v_payload || jsonb_build_object('parse_mode', p_parse_mode); END IF;
  IF p_reply_to_message_id IS NOT NULL THEN v_payload := v_payload || jsonb_build_object('reply_to_message_id', p_reply_to_message_id); END IF;

  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '5000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  WHILE v_attempt < v_max_attempts LOOP
    v_attempt := v_attempt + 1;
    BEGIN
      SELECT (extensions.http_post(
        'https://api.telegram.org/bot' || v_token || '/sendMessage',
        v_payload::text,
        'application/json'
      )).content::jsonb INTO v_resp;

      IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
        RETURN v_resp || jsonb_build_object('bot_used', p_bot);
      END IF;
      IF v_resp IS NOT NULL AND v_resp ? 'error_code' THEN
        RETURN v_resp || jsonb_build_object('bot_used', p_bot);
      END IF;
      v_last_err := 'unexpected response: ' || coalesce(v_resp::text, 'null');
    EXCEPTION WHEN OTHERS THEN
      v_last_err := 'exception: ' || SQLERRM;
    END;
    IF v_attempt < v_max_attempts THEN PERFORM pg_sleep(1.5); END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', false, 'error', v_last_err, 'attempts', v_attempt, 'bot_used', p_bot);
END;
$$;

-- Update the nag handlers to use paper_newt_bot for personal DMs to Peter
CREATE OR REPLACE FUNCTION public.payroll_weekly_nag(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','net','pg_catalog'
AS $$
DECLARE
  v_url               text;
  v_secret            text;
  v_target_sat        date;
  v_next_wed          date;
  v_run_exists        boolean;
  v_existing_alert_id uuid;
  v_mod_ref           text;
  v_title             text;
  v_message           text;
  v_peter_tg          bigint;
  v_tg_resp           jsonb;
  v_dm_text           text;
  v_action_taken      text := 'no-op';
BEGIN
  v_target_sat := current_date - ((extract(dow from current_date)::int + 1) % 7);
  v_next_wed   := v_target_sat + 4;
  v_mod_ref    := 'payroll_run:' || v_target_sat::text;

  BEGIN
    SELECT setting_value INTO v_url    FROM public.settings WHERE agency_id=p_agency_id AND setting_key='supabase_url';
    SELECT setting_value INTO v_secret FROM public.settings WHERE agency_id=p_agency_id AND setting_key='automation_runner_cron_secret';
    IF v_url IS NOT NULL AND v_secret IS NOT NULL THEN
      PERFORM net.http_post(
        url     := v_url || '/functions/v1/payroll-email-parser',
        body    := jsonb_build_object('agency_id', p_agency_id, 'shared_secret', v_secret),
        headers := jsonb_build_object('Content-Type','application/json'),
        timeout_milliseconds := 60000
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  SELECT EXISTS (SELECT 1 FROM public.payroll_runs WHERE agency_id = p_agency_id AND pay_period_end = v_target_sat) INTO v_run_exists;
  IF v_run_exists THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', format('Payroll for week ending %s already imported; no nag needed.', v_target_sat));
  END IF;

  SELECT ttm.telegram_user_id INTO v_peter_tg FROM public.team_telegram_map ttm
   JOIN public.team t ON t.id = ttm.team_id WHERE t.first_name='Peter' AND t.last_name='Story' LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT id INTO v_existing_alert_id FROM public.alerts
   WHERE agency_id = p_agency_id AND module_reference = v_mod_ref AND COALESCE(is_resolved, false) = false LIMIT 1;

  v_title := format('Run payroll for week ending %s', to_char(v_target_sat, 'Mon DD'));
  v_message := format('No SurePayroll email received yet for pay period ending %s (transmit deadline: Wed %s). Submit payroll in SurePayroll, then forward the summary email to paper.newt.management@gmail.com so it lands in the BCC.',
    to_char(v_target_sat, 'Mon DD, YYYY'), to_char(v_next_wed, 'Mon DD'));

  IF v_existing_alert_id IS NULL THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, due_date, created_at)
    VALUES (p_agency_id, 'payroll_reminder', 'warning', v_title, v_message, v_mod_ref, false, false, v_next_wed, now());
    v_action_taken := 'alert_created_and_dm_sent';
  ELSE
    v_action_taken := 'dm_resent';
  END IF;

  v_dm_text := format(E'⏰ Payroll reminder\n\nWeek ending: %s\nTransmit deadline: Wed %s\n\nRun payroll in SurePayroll, then forward the summary email to paper.newt.management@gmail.com.\n\n(This nag will stop once the summary email is auto-imported.)',
    to_char(v_target_sat, 'Mon DD, YYYY'), to_char(v_next_wed, 'Mon DD'));
  v_tg_resp := public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s for week ending %s. Telegram DM ok=%s', v_action_taken, v_target_sat, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'target_pay_period_end', v_target_sat, 'transmit_deadline', v_next_wed, 'telegram_response', v_tg_resp
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.pfa_monthly_nag(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $$
DECLARE
  v_month_key         text := to_char(current_date, 'YYYY-MM');
  v_month_name        text := to_char(current_date, 'FMMonth YYYY');
  v_mod_ref           text := 'pfa_submission:' || v_month_key;
  v_due_date          date := (date_trunc('month', current_date) + interval '9 days')::date;
  v_existing_alert_id uuid;
  v_peter_tg          bigint;
  v_tg_resp           jsonb;
  v_dm_text           text;
  v_action_taken      text;
BEGIN
  SELECT ttm.telegram_user_id INTO v_peter_tg FROM public.team_telegram_map ttm
   JOIN public.team t ON t.id = ttm.team_id WHERE t.first_name='Peter' AND t.last_name='Story' LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT id INTO v_existing_alert_id FROM public.alerts
   WHERE agency_id = p_agency_id AND module_reference = v_mod_ref AND COALESCE(is_resolved, false) = false LIMIT 1;

  IF v_existing_alert_id IS NULL THEN
    IF extract(day from current_date) <= 10 THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, due_date, created_at)
      VALUES (p_agency_id, 'pfa_submission', 'warning',
        format('Submit PFA for %s', v_month_name),
        format('Submit this month''s Premium Fund Account (PFA) transaction in State Farm. Due by %s. Tap ''Mark Resolved'' on this alert once submitted.', to_char(v_due_date, 'FMMon DD')),
        v_mod_ref, false, false, v_due_date, now());
      v_action_taken := 'alert_created_and_dm_sent';
    ELSE
      RETURN jsonb_build_object('records_processed', 0, 'output_summary', format('No PFA alert for %s and past day 10; skipping.', v_month_key));
    END IF;
  ELSE
    v_action_taken := 'dm_resent';
  END IF;

  v_dm_text := format(E'💰 PFA reminder\n\n%s Premium Fund Account transaction is due by %s.\n\nSubmit it in State Farm, then tap "Mark Resolved" on the alert card in the BCC.',
    v_month_name, to_char(v_due_date, 'FMMon DD'));
  v_tg_resp := public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s for PFA %s. Telegram DM ok=%s', v_action_taken, v_month_key, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'month', v_month_key, 'due_date', v_due_date, 'telegram_response', v_tg_resp
  );
END;
$$;
