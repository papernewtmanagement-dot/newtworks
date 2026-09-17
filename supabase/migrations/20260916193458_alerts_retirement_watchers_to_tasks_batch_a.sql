-- Alerts retirement, phase 2, step 2.
-- Six functions whose alert was a real thing Peter has to act on. Each one now
-- writes a task through ensure_watcher_task instead, and closes it through
-- close_watcher_task when the condition clears. Dedupe is created_by =
-- 'watcher:<source>' plus related_id, open tasks only, so the task row does the
-- same job the open alert row used to do.

CREATE OR REPLACE FUNCTION public.agency_snapshot_weekly_alert(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_today      DATE := CURRENT_DATE;
  v_target_sat DATE;
  v_existing   public.agency_snapshot%ROWTYPE;
  v_source     TEXT;
  v_title      TEXT;
  v_message    TEXT;
  v_priority   TEXT;
  v_created    BOOLEAN;
BEGIN
  v_target_sat := v_today - ((EXTRACT(DOW FROM v_today)::int + 1) % 7);
  v_source := 'agency_snapshot_weekly:' || v_target_sat::text;

  SELECT * INTO v_existing
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date = v_target_sat
    AND cadence = 'weekly'
  LIMIT 1;

  IF FOUND THEN
    v_title    := 'Confirm this week''s agency snapshot (' || to_char(v_target_sat, 'Mon DD') || ')';
    v_message  := 'Auto-import from the SF CRM Analytics email landed. Open Financials > Book of Business > Add snapshot manually to review and fill in YTD new/lost counts, life paid_for count + premium, and IPS new money. The form will pre-fill with the parsed stock values.';
    v_priority := 'low';
  ELSE
    v_title    := 'Enter this week''s agency snapshot (' || to_char(v_target_sat, 'Mon DD') || ')';
    v_message  := 'No row found for ' || to_char(v_target_sat, 'Mon DD, YYYY') || ' yet. Either the SF CRM Analytics email did not arrive / parse, or it has not been forwarded. Open Financials > Book of Business > Add snapshot manually to enter this week''s numbers.';
    v_priority := 'medium';
  END IF;

  v_created := public.ensure_watcher_task(
    p_agency_id, v_source, NULL, v_title, v_message, v_priority, 'finances');

  RETURN jsonb_build_object(
    'records_processed', CASE WHEN v_created THEN 1 ELSE 0 END,
    'output_summary',
      CASE WHEN v_created
        THEN 'Task raised for week ending ' || v_target_sat::text || ' (' || v_priority || ').'
        ELSE 'Task already open for ' || v_target_sat::text || '; skipped.'
      END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.alert_unpurged_form_secure(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_names text; v_count integer;
BEGIN
  SELECT count(*), string_agg(t.first_name || ' ' || left(t.last_name,1) || '.', ', ')
    INTO v_count, v_names
    FROM public.team_form_secure sec
    JOIN public.team_form_submissions s ON s.id = sec.submission_id
    JOIN public.team t ON t.id = s.team_id
   WHERE sec.created_at < now() - INTERVAL '3 days';

  IF COALESCE(v_count,0) = 0 THEN
    PERFORM public.close_watcher_task(p_agency_id, 'unpurged_payroll_details', NULL);
    RETURN 0;
  END IF;

  PERFORM public.ensure_watcher_task(
    p_agency_id,
    'unpurged_payroll_details',
    NULL,
    'Bank details still stored for ' || v_count || ' team member(s)',
    v_names || ' submitted payroll details more than three days ago and they have not been destroyed yet. ' ||
    'Enter them in SurePayroll, then press Destroy on the team record.',
    'high',
    'admin');

  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.comp_net_deposit_notice(p_agency_id uuid, p_year integer, p_month integer, p_day integer, p_send boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_comp numeric; v_ded numeric; v_comp_n int; v_ded_n int;
  v_stated numeric; v_net numeric; v_label text; v_text text; v_id uuid; v_res jsonb;
  v_dry boolean := COALESCE(current_setting('newtworks.dry_run', true), '') = 'on';
  v_allow_fallback boolean := COALESCE(current_setting('newtworks.comp_notice_fallback', true), 'on') = 'on';
BEGIN
  SELECT
    COALESCE(SUM(amount) FILTER (WHERE COALESCE(comp_category,'') NOT LIKE 'deduction_%'), 0),
    COALESCE(SUM(amount) FILTER (WHERE comp_category LIKE 'deduction_%'), 0),
    COUNT(*) FILTER (WHERE COALESCE(comp_category,'') NOT LIKE 'deduction_%'),
    COUNT(*) FILTER (WHERE comp_category LIKE 'deduction_%')
  INTO v_comp, v_ded, v_comp_n, v_ded_n
  FROM comp_recap
  WHERE agency_id = p_agency_id AND period_year = p_year AND period_month = p_month
    AND period_day = p_day AND source_document_id IS NOT NULL;

  IF v_comp_n = 0 OR v_ded_n = 0 THEN
    RETURN jsonb_build_object('action', 'waiting', 'comp_rows', v_comp_n, 'deduction_rows', v_ded_n);
  END IF;

  SELECT MAX(d.stated_net_payable) INTO v_stated
  FROM documents d
  WHERE d.id IN (SELECT DISTINCT source_document_id FROM comp_recap
                 WHERE agency_id = p_agency_id AND period_year = p_year AND period_month = p_month
                   AND period_day = p_day AND source_document_id IS NOT NULL
                   AND COALESCE(comp_category,'') NOT LIKE 'deduction_%')
    AND d.stated_net_payable IS NOT NULL;

  IF v_stated IS NULL AND NOT v_allow_fallback THEN
    RETURN jsonb_build_object('action', 'waiting_for_stated_deposit', 'summed_net', v_comp - v_ded);
  END IF;

  v_net := COALESCE(v_stated, v_comp - v_ded);
  v_label := to_char(make_date(p_year, p_month, 1), 'Mon') || ' '
          || CASE WHEN p_day <= 15 THEN '1-15' ELSE '16-' || p_day END;
  v_text := '💰 Comp statement processed for ' || v_label || '.' || E'\n'
         || 'Net deposit: ' || to_char(v_net, 'FM$999,999,990.00');

  IF NOT p_send OR v_dry THEN
    RETURN jsonb_build_object('action', 'dry_run', 'stated_deposit', v_stated,
      'summed_net', v_comp - v_ded, 'net_deposit', v_net, 'message', v_text);
  END IF;

  INSERT INTO comp_deposit_notices (agency_id, period_year, period_month, period_day,
    comp_total, deduction_total, net_deposit, message_text)
  VALUES (p_agency_id, p_year, p_month, p_day, v_comp, v_ded, v_net, v_text)
  ON CONFLICT (agency_id, period_year, period_month, period_day) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('action', 'already_sent');
  END IF;

  BEGIN
    IF v_stated IS NOT NULL AND abs(v_stated - (v_comp - v_ded)) >= 0.01 THEN
      PERFORM public.ensure_watcher_task(
        p_agency_id,
        'comp_deposit_mismatch',
        v_id,
        'Comp records do not match the ' || v_label || ' deposit',
        'State Farm deposited ' || to_char(v_stated, 'FM$999,999,990.00')
          || '. Comp statement lines minus deductions come to ' || to_char(v_comp - v_ded, 'FM$999,999,990.00')
          || '. Off by ' || to_char(abs(v_stated - (v_comp - v_ded)), 'FM$999,999,990.00')
          || '. A line on the statement was not captured.',
        'high',
        'finances');
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    v_res := public.telegram_send('admin', v_text, p_agency_id);
    UPDATE comp_deposit_notices
       SET status = CASE WHEN (v_res->>'ok')::boolean IS TRUE THEN 'sent' ELSE 'failed' END,
           telegram_result = v_res,
           sent_at = CASE WHEN (v_res->>'ok')::boolean IS TRUE THEN now() END
     WHERE id = v_id;
  EXCEPTION WHEN OTHERS THEN
    UPDATE comp_deposit_notices SET status = 'failed',
           telegram_result = jsonb_build_object('error', SQLERRM)
     WHERE id = v_id;
  END;

  RETURN jsonb_build_object('action', 'sent', 'net_deposit', v_net, 'telegram', v_res);
END;
$function$;

CREATE OR REPLACE FUNCTION public.resweep_failed_automation_dispatches()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
DECLARE
  v_row     RECORD;
  v_dead    RECORD;
  v_retried INTEGER := 0;
  v_new_req BIGINT;
BEGIN
  FOR v_row IN
    SELECT d.id, d.recipe_id, d.retry_count, r.recipe_name, r.agency_id
    FROM public.automation_dispatch_log d
    JOIN public.automation_recipes r ON r.id = d.recipe_id
    JOIN net._http_response resp ON resp.id = d.request_id
    WHERE d.resolved_at IS NULL
      AND d.retry_count < 2
      AND d.dispatched_at > now() - INTERVAL '3 hours'
      AND d.dispatched_at < now() - INTERVAL '2 minutes'
      AND r.is_active = TRUE
      AND (resp.status_code IS NULL OR resp.status_code >= 400 OR resp.timed_out)
      AND NOT EXISTS (
        SELECT 1 FROM public.automation_run_log l
        WHERE l.recipe_id = d.recipe_id AND l.run_at >= d.dispatched_at
          AND l.is_pre_run_failure = FALSE)
    ORDER BY d.dispatched_at
  LOOP
    BEGIN
      v_new_req := public.run_automation_recipe(v_row.recipe_id, 'pg_cron_resweep');
      UPDATE public.automation_dispatch_log
      SET retry_count = v_row.retry_count + 1, resolved_at = now()
      WHERE id = v_row.id;
      INSERT INTO public.automation_dispatch_log (recipe_id, request_id, retry_count)
      VALUES (v_row.recipe_id, v_new_req, v_row.retry_count + 1);
      v_retried := v_retried + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.automation_dispatch_log SET resolved_at = now() WHERE id = v_row.id;
    END;
  END LOOP;

  -- A dispatch that burned both attempts is a real failure, not a blip. One
  -- open task per recipe until the recipe runs again.
  FOR v_dead IN
    SELECT DISTINCT r.id AS recipe_id, r.agency_id, r.recipe_name,
           COALESCE(r.last_run_at, r.created_at) AS last_seen
    FROM public.automation_dispatch_log d
    JOIN public.automation_recipes r ON r.id = d.recipe_id
    WHERE d.retry_count >= 2
      AND d.resolved_at IS NULL
      AND d.dispatched_at > now() - INTERVAL '3 hours'
      AND NOT EXISTS (
        SELECT 1 FROM public.automation_run_log l
        WHERE l.recipe_id = d.recipe_id AND l.run_at >= d.dispatched_at
          AND l.is_pre_run_failure = FALSE)
  LOOP
    PERFORM public.ensure_watcher_task(
      v_dead.agency_id,
      'automation_dispatch_failed',
      v_dead.recipe_id,
      'Automation dispatch failed twice: ' || v_dead.recipe_name,
      format('The runner queued %s twice and the edge function did not answer either time. It has not run since %s Central.',
             v_dead.recipe_name,
             to_char(v_dead.last_seen AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD HH24:MI')),
      'high',
      'web_app');
  END LOOP;

  UPDATE public.automation_dispatch_log SET resolved_at = now()
  WHERE resolved_at IS NULL AND dispatched_at < now() - INTERVAL '3 hours';

  DELETE FROM public.automation_dispatch_log WHERE dispatched_at < now() - INTERVAL '7 days';

  RETURN v_retried;
END;
$function$;

CREATE OR REPLACE FUNCTION public.payroll_weekly_nag(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_url text; v_secret text; v_target_sat date; v_next_wed date; v_run_exists boolean;
  v_peter_tg bigint; v_tg_resp jsonb; v_dm_text text;
BEGIN
  v_target_sat := current_date - ((extract(dow from current_date)::int + 1) % 7);
  v_next_wed := v_target_sat + 4;

  BEGIN
    SELECT setting_value INTO v_url FROM public.settings WHERE agency_id=p_agency_id AND setting_key='supabase_url';
    SELECT setting_value INTO v_secret FROM public.settings WHERE agency_id=p_agency_id AND setting_key='automation_runner_cron_secret';
    IF v_url IS NOT NULL AND v_secret IS NOT NULL THEN
      PERFORM net.http_post(url := v_url || '/functions/v1/payroll-email-parser',
        body := jsonb_build_object('agency_id', p_agency_id, 'shared_secret', v_secret),
        headers := public.edge_fn_headers(), timeout_milliseconds := 60000);
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  SELECT EXISTS (SELECT 1 FROM public.payroll_runs WHERE agency_id = p_agency_id AND pay_period_end = v_target_sat) INTO v_run_exists;
  IF v_run_exists THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', format('Payroll for week ending %s already imported; no nag needed.', v_target_sat));
  END IF;

  SELECT t.telegram_user_id INTO v_peter_tg FROM public.team t
   WHERE t.first_name='Peter' AND t.last_name='Story' AND t.telegram_user_id IS NOT NULL LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  v_dm_text := format(E'⏰ Payroll reminder\n\nWeek ending: %s\nTransmit deadline: Wed %s\n\nRun payroll in SurePayroll, then forward the summary email to paper.newt.management@gmail.com.\n\n(This nag will stop once the summary email is auto-imported.)',
    to_char(v_target_sat, 'Mon DD, YYYY'), to_char(v_next_wed, 'Mon DD'));
  v_tg_resp := public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('Telegram reminder sent for week ending %s. ok=%s', v_target_sat, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'target_pay_period_end', v_target_sat, 'transmit_deadline', v_next_wed, 'telegram_response', v_tg_resp);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pfa_monthly_nag(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_stmt_end_date date := (date_trunc('month', current_date) - interval '1 day')::date;
  v_month_key text := to_char(v_stmt_end_date, 'YYYY-MM');
  v_month_name text := to_char(v_stmt_end_date, 'FMMonth YYYY');
  v_source text := 'pfa_statement_ingest:' || v_month_key;
  v_pfa_account_id uuid; v_statement_id uuid; v_peter_tg bigint;
  v_task_open boolean; v_closed integer; v_created boolean;
  v_tg_resp jsonb; v_dm_text text; v_action_taken text;
BEGIN
  SELECT t.telegram_user_id INTO v_peter_tg FROM public.team t
  WHERE t.first_name='Peter' AND t.last_name='Story' AND t.telegram_user_id IS NOT NULL LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT id INTO v_pfa_account_id FROM public.pfa_accounts
  WHERE agency_id = p_agency_id AND is_active = true LIMIT 1;
  IF v_pfa_account_id IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No active PFA account for agency; skipping.');
  END IF;

  SELECT id INTO v_statement_id FROM public.pfa_bank_statements
  WHERE pfa_account_id = v_pfa_account_id AND statement_period_end = v_stmt_end_date LIMIT 1;

  SELECT EXISTS (
    SELECT 1 FROM public.tasks t
    WHERE t.agency_id = p_agency_id AND t.created_by = 'watcher:' || v_source
      AND t.related_id IS NULL AND t.status = 'open'
  ) INTO v_task_open;

  IF v_statement_id IS NOT NULL THEN
    v_closed := public.close_watcher_task(p_agency_id, v_source, NULL);
    RETURN jsonb_build_object('records_processed', v_closed,
      'output_summary', format('Statement %s ingested; %s task(s) closed.', v_month_key, v_closed),
      'month', v_month_key, 'statement_id', v_statement_id);
  END IF;

  IF NOT v_task_open THEN
    IF extract(day from current_date) <= 10 THEN
      v_created := public.ensure_watcher_task(
        p_agency_id, v_source, NULL,
        format('Send Frost PFA statement for %s', v_month_name),
        format('Forward the Frost Bank PFA statement PDF for %s to paper.newt.management@gmail.com. Newtworks will auto-reconcile and email SF. This task closes itself when the statement lands.', v_month_name),
        'medium', 'finances');
      v_action_taken := 'task_created_and_dm_sent';
    ELSE
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('No statement for %s and past day 10; skipping.', v_month_key));
    END IF;
  ELSE v_action_taken := 'dm_resent'; END IF;

  v_dm_text := format(E'📄 PFA statement reminder\n\nThe Frost Bank PFA statement for %s hasn''t been received yet. Forward the statement PDF to paper.newt.management@gmail.com.\n\nOnce ingested, Newtworks auto-reconciles and emails the printout to SF. This task closes itself when the statement lands.', v_month_name);
  v_tg_resp := public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('%s for PFA statement %s. Telegram DM ok=%s', v_action_taken, v_month_key, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'month', v_month_key, 'telegram_response', v_tg_resp);
END;
$function$;
