-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-07 01:17:35 UTC (ledger name: payroll_and_pfa_nag_handlers) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260707011735.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- ===================================================================
-- 1. dispatch_payroll_email_parser: fires the edge function via pg_net
-- ===================================================================
CREATE OR REPLACE FUNCTION public.dispatch_payroll_email_parser(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','net','pg_catalog'
AS $$
DECLARE
  v_url        text;
  v_secret     text;
  v_request_id bigint;
BEGIN
  SELECT setting_value INTO v_url FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'supabase_url';
  IF v_url IS NULL THEN
    RAISE EXCEPTION 'supabase_url missing from settings for agency %', p_agency_id;
  END IF;
  v_url := v_url || '/functions/v1/payroll-email-parser';

  SELECT setting_value INTO v_secret FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'automation_runner_cron_secret missing from settings for agency %', p_agency_id;
  END IF;

  SELECT net.http_post(
    url     := v_url,
    body    := jsonb_build_object('agency_id', p_agency_id, 'shared_secret', v_secret),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 120000
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'request_id',       v_request_id,
    'target_function',  'payroll-email-parser',
    'output_summary',   format('Dispatched payroll-email-parser (request_id %s).', v_request_id),
    'records_processed', 0
  );
END;
$$;

-- ===================================================================
-- 2. payroll_weekly_nag: Sun/Mon/Tue/Wed morning nag
--    - Dispatches the parser fire-and-forget (catches morning forwards)
--    - Checks whether payroll_run exists for the current pay period
--    - If not, creates/refreshes alert AND sends Telegram DM to Peter
-- ===================================================================
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
  -- Compute the most recent Saturday (pay_period_end for the current pay cycle).
  v_target_sat := current_date - ((extract(dow from current_date)::int + 1) % 7);
  v_next_wed   := v_target_sat + 4;  -- Sat + 4 days = Wed (transmit deadline)
  v_mod_ref    := 'payroll_run:' || v_target_sat::text;

  -- Fire-and-forget dispatch the parser (catches any just-forwarded email)
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
  EXCEPTION WHEN OTHERS THEN
    -- Non-fatal: continue with nag logic even if dispatch fails
    NULL;
  END;

  -- Check if a payroll_run exists for this pay period
  SELECT EXISTS (
    SELECT 1 FROM public.payroll_runs
    WHERE agency_id = p_agency_id AND pay_period_end = v_target_sat
  ) INTO v_run_exists;

  IF v_run_exists THEN
    -- Already got the email + parsed; parser handles alert-resolve.
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Payroll for week ending %s already imported; no nag needed.', v_target_sat)
    );
  END IF;

  -- Peter's Telegram user_id (fallback to hardcoded if map missing)
  SELECT ttm.telegram_user_id INTO v_peter_tg
  FROM public.team_telegram_map ttm
  JOIN public.team t ON t.id = ttm.team_id
  WHERE t.first_name='Peter' AND t.last_name='Story'
  LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  -- Check for existing unresolved alert for this pay period
  SELECT id INTO v_existing_alert_id
  FROM public.alerts
  WHERE agency_id = p_agency_id
    AND module_reference = v_mod_ref
    AND COALESCE(is_resolved, false) = false
  LIMIT 1;

  v_title := format('Run payroll for week ending %s', to_char(v_target_sat, 'Mon DD'));
  v_message := format(
    'No SurePayroll email received yet for pay period ending %s (transmit deadline: Wed %s). Submit payroll in SurePayroll, then forward the summary email to paper.newt.management@gmail.com so it lands in the BCC.',
    to_char(v_target_sat, 'Mon DD, YYYY'),
    to_char(v_next_wed, 'Mon DD')
  );

  IF v_existing_alert_id IS NULL THEN
    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, is_read, is_resolved, due_date, created_at
    ) VALUES (
      p_agency_id, 'payroll_reminder', 'warning', v_title, v_message,
      v_mod_ref, false, false, v_next_wed, now()
    );
    v_action_taken := 'alert_created_and_dm_sent';
  ELSE
    v_action_taken := 'dm_resent';
  END IF;

  -- Nag Peter via Telegram every time (Sun/Mon/Tue/Wed) until payroll runs
  v_dm_text := format(
    E'⏰ Payroll reminder\n\nWeek ending: %s\nTransmit deadline: Wed %s\n\nRun payroll in SurePayroll, then forward the summary email to paper.newt.management@gmail.com.\n\n(This nag will stop once the summary email is auto-imported.)',
    to_char(v_target_sat, 'Mon DD, YYYY'),
    to_char(v_next_wed, 'Mon DD')
  );
  v_tg_resp := public.telegram_send_message(v_peter_tg, v_dm_text, NULL, NULL);

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s for week ending %s. Telegram DM ok=%s',
      v_action_taken, v_target_sat, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'target_pay_period_end', v_target_sat,
    'transmit_deadline', v_next_wed,
    'telegram_response', v_tg_resp
  );
END;
$$;

-- ===================================================================
-- 3. pfa_monthly_nag: daily reminder for monthly PFA (Premium Fund Account)
--    - On day 1 of month: create alert (module_reference='pfa_submission:<YYYY-MM>')
--    - Every day thereafter (until manually resolved): DM Peter
--    - Resolution via manual "Mark Resolved" button on alert card
-- ===================================================================
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
  v_due_date          date := (date_trunc('month', current_date) + interval '9 days')::date;  -- Due by 10th
  v_existing_alert_id uuid;
  v_peter_tg          bigint;
  v_tg_resp           jsonb;
  v_dm_text           text;
  v_action_taken      text;
BEGIN
  -- Peter's Telegram
  SELECT ttm.telegram_user_id INTO v_peter_tg
  FROM public.team_telegram_map ttm
  JOIN public.team t ON t.id = ttm.team_id
  WHERE t.first_name='Peter' AND t.last_name='Story' LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  -- Existing unresolved alert for this month?
  SELECT id INTO v_existing_alert_id
  FROM public.alerts
  WHERE agency_id = p_agency_id
    AND module_reference = v_mod_ref
    AND COALESCE(is_resolved, false) = false
  LIMIT 1;

  IF v_existing_alert_id IS NULL THEN
    -- Only create on day 1 (or on first run after day 1 if handler was down); after 10th assume they're way behind
    IF extract(day from current_date) <= 10 THEN
      INSERT INTO public.alerts (
        agency_id, alert_type, severity, title, message,
        module_reference, is_read, is_resolved, due_date, created_at
      ) VALUES (
        p_agency_id, 'pfa_submission', 'warning',
        format('Submit PFA for %s', v_month_name),
        format('Submit this month''s Premium Fund Account (PFA) transaction in State Farm. Due by %s. Tap ''Mark Resolved'' on this alert once submitted.',
               to_char(v_due_date, 'FMMon DD')),
        v_mod_ref, false, false, v_due_date, now()
      );
      v_action_taken := 'alert_created_and_dm_sent';
    ELSE
      -- Past day 10 and no alert → skip creating retroactively
      RETURN jsonb_build_object('records_processed', 0, 'output_summary', format('No PFA alert for %s and past day 10; skipping.', v_month_key));
    END IF;
  ELSE
    v_action_taken := 'dm_resent';
  END IF;

  -- DM Peter
  v_dm_text := format(
    E'💰 PFA reminder\n\n%s Premium Fund Account transaction is due by %s.\n\nSubmit it in State Farm, then tap "Mark Resolved" on the alert card in the BCC.',
    v_month_name, to_char(v_due_date, 'FMMon DD')
  );
  v_tg_resp := public.telegram_send_message(v_peter_tg, v_dm_text, NULL, NULL);

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s for PFA %s. Telegram DM ok=%s', v_action_taken, v_month_key, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'month', v_month_key,
    'due_date', v_due_date,
    'telegram_response', v_tg_resp
  );
END;
$$;

COMMENT ON FUNCTION public.dispatch_payroll_email_parser IS 'Fires payroll-email-parser edge function via pg_net. Returns request_id for automation-runner polling.';
COMMENT ON FUNCTION public.payroll_weekly_nag IS 'Sun/Mon/Tue/Wed 7am CT reminder. Dispatches parser first, then nags Peter via Telegram if no payroll_run exists for current pay week. Alert auto-closes when parser imports.';
COMMENT ON FUNCTION public.pfa_monthly_nag IS 'Daily reminder for monthly Premium Fund Account submission. Creates alert on/before day 10, DMs Peter until manually marked resolved.';
