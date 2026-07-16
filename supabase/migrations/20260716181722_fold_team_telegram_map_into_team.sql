-- Migration: fold team_telegram_map (3 essential columns) into team, rewrite 12 functions, drop table
-- Verified 2026-07-16: 12 SQL functions reference team_telegram_map, 0 views/triggers/FKs/repo refs
-- Columns pruned: telegram_username (all NULL, dead code path), telegram_first_name/last_name (display only,
-- swapped to team.first_name/last_name), excluded_reason/mapping_method/first_seen_at/last_seen_at (0 fn refs)

-- Step 1: Add 3 essential columns to team
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS telegram_user_id BIGINT,
  ADD COLUMN IF NOT EXISTS is_excluded_pjsagencybot BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS is_excluded_paper_newt_bot BOOLEAN NOT NULL DEFAULT FALSE;

-- Step 2: Backfill from team_telegram_map
UPDATE public.team t
SET telegram_user_id = ttm.telegram_user_id,
    is_excluded_pjsagencybot = ttm.is_excluded_pjsagencybot,
    is_excluded_paper_newt_bot = ttm.is_excluded_paper_newt_bot
FROM public.team_telegram_map ttm
WHERE ttm.team_id = t.id;

-- Step 3: Unique index on telegram_user_id (partial, allows multiple NULLs)
CREATE UNIQUE INDEX IF NOT EXISTS ux_team_telegram_user_id
  ON public.team (telegram_user_id) WHERE telegram_user_id IS NOT NULL;

-- ============================================================================
-- Step 4: Rewrite 12 functions to read from team directly
-- ============================================================================

-- 4a. dispatch_task_reminders
CREATE OR REPLACE FUNCTION public.dispatch_task_reminders()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_chat_id bigint;
  v_now timestamptz := NOW();
  v_recipe_id uuid;
  v_run_start timestamptz := clock_timestamp();
  v_task RECORD;
  v_msg text;
  v_local_due text;
  v_count int := 0;
  v_ids uuid[] := ARRAY[]::uuid[];
  v_out jsonb;
BEGIN
  SELECT id INTO v_recipe_id
  FROM public.automation_recipes
  WHERE recipe_name = 'Task Reminder Dispatcher' AND agency_id = v_agency_id
  LIMIT 1;

  SELECT t.telegram_user_id INTO v_chat_id
  FROM public.team t
  WHERE t.agency_id = v_agency_id
    AND t.role_level = 'Owner'
    AND t.is_excluded_paper_newt_bot = false
    AND t.telegram_user_id IS NOT NULL
  LIMIT 1;

  IF v_chat_id IS NULL THEN
    v_out := jsonb_build_object(
      'records_processed', 0,
      'output_summary', 'skipped: no owner telegram_user_id on team (paper_newt_bot channel)');
    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
      VALUES (v_agency_id, v_recipe_id, v_now, 'success', 0, v_out->>'output_summary',
              ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_run_start)))::int);
    END IF;
    RETURN v_out;
  END IF;

  FOR v_task IN
    SELECT id, title, due_at, priority, task_type
    FROM public.tasks
    WHERE agency_id = v_agency_id
      AND remind_via_telegram = true
      AND due_at IS NOT NULL
      AND reminded_at IS NULL
      AND status = 'open'
      AND due_at <= v_now + INTERVAL '60 minutes'
    ORDER BY due_at
    LIMIT 50
  LOOP
    v_local_due := to_char(v_task.due_at AT TIME ZONE 'America/Chicago', 'FMDay Mon FMDD, FMHH12:MI AM');
    v_msg := format(
      E'⏰ Task reminder\n\n%s\n\nDue: %s CT\nPriority: %s\n\nOpen Newtworks → Tasks & Goals',
      v_task.title, v_local_due, COALESCE(v_task.priority, 'medium')
    );
    BEGIN
      PERFORM public.telegram_send_message_v2(v_chat_id, v_msg, 'paper_newt');
      UPDATE public.tasks SET reminded_at = v_now WHERE id = v_task.id;
      v_ids := array_append(v_ids, v_task.id);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'dispatch_task_reminders: telegram send failed for task % (%): %', v_task.id, v_task.title, SQLERRM;
    END;
  END LOOP;

  v_out := jsonb_build_object(
    'records_processed', v_count,
    'output_summary', CASE WHEN v_count = 0 THEN 'no tasks due within 60 min'
                            ELSE format('sent %s reminder(s)', v_count) END,
    'task_ids', to_jsonb(v_ids)
  );

  IF v_recipe_id IS NOT NULL THEN
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_now, 'success', v_count, v_out->>'output_summary',
            ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_run_start)))::int);
  END IF;

  RETURN v_out;
END;
$function$;

-- 4b. leslie_monthly_capture_reply (trigger fn)
CREATE OR REPLACE FUNCTION public.leslie_monthly_capture_reply()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_chat_id BIGINT;
  v_group_chat_id BIGINT;
  v_marie_team_id UUID := 'd7431075-d29f-4833-9503-430945894b04';
  v_speaker_team_id UUID;
  v_row_id UUID;
BEGIN
  IF NEW.role <> 'user' OR NEW.speaker_telegram_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT cc.telegram_chat_id INTO v_chat_id
  FROM public.chatbot_conversations cc
  WHERE cc.id = NEW.conversation_id;

  IF v_chat_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT setting_value::bigint INTO v_group_chat_id
  FROM public.settings
  WHERE agency_id = NEW.agency_id
    AND setting_key = 'paper_newt_management_group_chat_id';

  IF v_group_chat_id IS NULL OR v_chat_id <> v_group_chat_id THEN
    RETURN NEW;
  END IF;

  SELECT t.id INTO v_speaker_team_id
  FROM public.team t
  WHERE t.agency_id = NEW.agency_id
    AND t.telegram_user_id = NEW.speaker_telegram_user_id;

  IF v_speaker_team_id IS DISTINCT FROM v_marie_team_id THEN
    RETURN NEW;
  END IF;

  SELECT id INTO v_row_id
  FROM public.leslie_monthly_checkin
  WHERE agency_id = NEW.agency_id
    AND sent_at IS NOT NULL
    AND sent_at < NEW.created_at
    AND marie_reply_text IS NULL
  ORDER BY sent_at DESC
  LIMIT 1;

  IF v_row_id IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE public.leslie_monthly_checkin
  SET marie_reply_text = NEW.content,
      marie_reply_at = NEW.created_at,
      marie_reply_message_id = NEW.telegram_message_id,
      updated_at = NOW()
  WHERE id = v_row_id;

  RETURN NEW;
END;
$function$;

-- 4c. leslie_monthly_goals_send
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

  SELECT t.telegram_user_id INTO v_marie_user_id
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND t.id = 'd7431075-d29f-4833-9503-430945894b04'
    AND COALESCE(t.is_excluded_paper_newt_bot, false) = false
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
$function$;

-- 4d. nudge_peter_for_cpr_drafts
CREATE OR REPLACE FUNCTION public.nudge_peter_for_cpr_drafts()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_agency_id     uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_recipe_id     uuid;
  v_run_started   timestamptz := now();
  v_now_ct        timestamp;
  v_today_ct      date;
  v_hour_ct       int;
  v_week_end      date;
  v_dow           int;
  v_report        record;
  v_peter_chat_id bigint;
  v_message       text;
  v_state         text;
  v_send_resp     jsonb;
  v_result        jsonb;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'weekly_cpr_nudge_peter' LIMIT 1;

  v_now_ct   := (NOW() AT TIME ZONE 'America/Chicago');
  v_today_ct := v_now_ct::date;
  v_hour_ct  := EXTRACT(HOUR FROM v_now_ct)::int;
  v_dow      := EXTRACT(DOW FROM v_today_ct)::int;
  v_week_end := v_today_ct - ((v_dow + 1) % 7);

  IF v_hour_ct <> 18 OR v_dow NOT IN (0, 6) THEN
    v_result := jsonb_build_object('skipped', 'wrong_dst_cron_fire', 'hour_ct', v_hour_ct, 'dow_ct', v_dow);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'success',
            'Skipped: wrong-DST cron fire (intended Sat/Sun 6 PM CT, got DOW ' || v_dow || ' hour ' || v_hour_ct || ')',
            EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  SELECT * INTO v_report FROM public.weekly_cpr_reports
   WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;

  IF FOUND AND v_report.sent_to_team_at IS NOT NULL THEN
    v_result := jsonb_build_object('skipped', 'already_sent', 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'skipped', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  IF FOUND
     AND v_report.opener_text IS NOT NULL AND length(btrim(v_report.opener_text)) >= 100
     AND v_report.looking_next_week_text IS NOT NULL AND length(btrim(v_report.looking_next_week_text)) >= 50 THEN
    v_result := jsonb_build_object('skipped', 'drafts_ready', 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'skipped', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  SELECT t.telegram_user_id INTO v_peter_chat_id
  FROM public.team t
  WHERE t.agency_id = v_agency_id
    AND t.role_level = 'Owner'
    AND t.is_admin_backoffice = false
    AND coalesce(t.is_excluded_pjsagencybot, false) = false
    AND t.telegram_user_id IS NOT NULL
  LIMIT 1;

  IF v_peter_chat_id IS NULL THEN
    v_result := jsonb_build_object('error', 'no_telegram_user_id_for_peter');
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', 'No telegram_user_id found for Owner', EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  IF NOT FOUND OR v_report IS NULL THEN
    v_state := 'no_row';
  ELSIF v_report.auto_ratio_pct IS NOT NULL AND v_report.fire_ratio_pct IS NOT NULL THEN
    v_state := 'form_filled_drafts_pending';
  ELSE
    v_state := 'form_empty';
  END IF;

  IF v_state = 'form_filled_drafts_pending' THEN
    v_message := E'📊 CPR check-in\n\n'
              || E'The form is filled but drafts aren''t in yet.\n\n'
              || E'⏳ Ping Claude to draft the opener + looking-ahead. Cron auto-sends at 6 AM CT once drafts land.\n\n'
              || 'Week ending: ' || v_week_end::text;
  ELSE
    v_message := E'📊 CPR check-in\n\n'
              || E'The CPR form isn''t filled in yet. Auto-send needs both form data + Claude drafts.\n\n'
              || E'Fill the form, then ping Claude.\n\n'
              || 'Week ending: ' || v_week_end::text;
  END IF;

  v_send_resp := public.paper_newt_send_message(v_peter_chat_id, v_message);

  IF v_send_resp IS NULL OR (v_send_resp->>'ok')::boolean IS NOT TRUE THEN
    v_result := jsonb_build_object('nudged', false, 'state', v_state,
      'telegram_error', v_send_resp->>'description',
      'telegram_code', v_send_resp->>'error_code',
      'send_response', v_send_resp, 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed',
            'Telegram send failed: ' || coalesce(v_send_resp->>'description', v_send_resp->>'error', 'unknown'),
            v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  v_result := jsonb_build_object('nudged', true, 'state', v_state,
    'telegram_message_id', v_send_resp->'result'->>'message_id', 'week_ending_date', v_week_end);
  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'success', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);

  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', SQLERRM, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  RAISE;
END;
$function$;

-- 4e. payroll_weekly_nag
CREATE OR REPLACE FUNCTION public.payroll_weekly_nag(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
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

  SELECT t.telegram_user_id INTO v_peter_tg FROM public.team t
   WHERE t.first_name='Peter' AND t.last_name='Story' AND t.telegram_user_id IS NOT NULL LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT id INTO v_existing_alert_id FROM public.alerts
   WHERE agency_id = p_agency_id AND module_reference = v_mod_ref AND COALESCE(is_resolved, false) = false LIMIT 1;

  v_title := format('Run payroll for week ending %s', to_char(v_target_sat, 'Mon DD'));
  v_message := format('No SurePayroll email received yet for pay period ending %s (transmit deadline: Wed %s). Submit payroll in SurePayroll, then forward the summary email to paper.newt.management@gmail.com so it lands in Newtworks.',
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
$function$;

-- 4f. pfa_monthly_nag
CREATE OR REPLACE FUNCTION public.pfa_monthly_nag(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_stmt_end_date     date := (date_trunc('month', current_date) - interval '1 day')::date;
  v_month_key         text := to_char(v_stmt_end_date, 'YYYY-MM');
  v_month_name        text := to_char(v_stmt_end_date, 'FMMonth YYYY');
  v_mod_ref           text := 'pfa_statement_ingest:' || v_month_key;
  v_due_date          date := (date_trunc('month', current_date) + interval '9 days')::date;
  v_pfa_account_id    uuid;
  v_existing_alert_id uuid;
  v_statement_id      uuid;
  v_peter_tg          bigint;
  v_tg_resp           jsonb;
  v_dm_text           text;
  v_action_taken      text;
BEGIN
  SELECT t.telegram_user_id INTO v_peter_tg
  FROM public.team t
  WHERE t.first_name='Peter' AND t.last_name='Story' AND t.telegram_user_id IS NOT NULL LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT id INTO v_pfa_account_id
  FROM public.pfa_accounts
  WHERE agency_id = p_agency_id AND is_active = true
  LIMIT 1;

  IF v_pfa_account_id IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'No active PFA account for agency; skipping.');
  END IF;

  SELECT id INTO v_statement_id
  FROM public.pfa_bank_statements
  WHERE pfa_account_id = v_pfa_account_id
    AND statement_period_end = v_stmt_end_date
  LIMIT 1;

  SELECT id INTO v_existing_alert_id
  FROM public.alerts
  WHERE agency_id = p_agency_id
    AND module_reference = v_mod_ref
    AND COALESCE(is_resolved, false) = false
  LIMIT 1;

  IF v_statement_id IS NOT NULL THEN
    IF v_existing_alert_id IS NOT NULL THEN
      UPDATE public.alerts
      SET is_resolved = true, resolved_at = now()
      WHERE id = v_existing_alert_id;
      RETURN jsonb_build_object(
        'records_processed', 1,
        'output_summary', format('Statement %s ingested; alert auto-resolved.', v_month_key),
        'month', v_month_key, 'statement_id', v_statement_id
      );
    END IF;
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Statement %s ingested; no alert to resolve.', v_month_key)
    );
  END IF;

  IF v_existing_alert_id IS NULL THEN
    IF extract(day from current_date) <= 10 THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, due_date, created_at)
      VALUES (p_agency_id, 'pfa_statement_ingest', 'warning',
        format('Send Frost PFA statement for %s', v_month_name),
        format('Forward the Frost Bank PFA statement PDF for %s to paper.newt.management@gmail.com. Newtworks will auto-reconcile and email SF. This alert auto-resolves when the statement lands.', v_month_name),
        v_mod_ref, false, false, v_due_date, now());
      v_action_taken := 'alert_created_and_dm_sent';
    ELSE
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('No statement for %s and past day 10; skipping.', v_month_key));
    END IF;
  ELSE
    v_action_taken := 'dm_resent';
  END IF;

  v_dm_text := format(
    E'📄 PFA statement reminder\n\nThe Frost Bank PFA statement for %s hasn''t been received yet. Forward the statement PDF to paper.newt.management@gmail.com.\n\nOnce ingested, Newtworks auto-reconciles and emails the printout to SF. This alert auto-resolves when the statement lands.',
    v_month_name);
  v_tg_resp := public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s for PFA statement %s. Telegram DM ok=%s',
      v_action_taken, v_month_key, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'month', v_month_key, 'due_date', v_due_date, 'telegram_response', v_tg_resp
  );
END;
$function$;

-- 4g. pfa_monthly_reconciliation
CREATE OR REPLACE FUNCTION public.pfa_monthly_reconciliation(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_pfa_account_id             uuid;
  v_statement                  record;
  v_prev_recon                 record;
  v_prior_personal_funds       numeric;
  v_current_bank_service_fees  numeric;
  v_outstanding_checks_total   numeric;
  v_outstanding_sf_eft_total   numeric;
  v_outstanding_deposits_total numeric;
  v_returned_checks_unreim     numeric := 0;
  v_adjusted_statement_balance numeric;
  v_difference                 numeric;
  v_recon_id                   uuid;
  v_processed_count            int := 0;
  v_peter_tg                   bigint;
  v_dm_text                    text;
  v_alert_title                text;
  v_alert_message              text;
  v_results                    jsonb := '[]'::jsonb;
  v_shared_secret              text;
  v_send_resp                  jsonb;
  v_send_ok                    boolean;
  v_send_status                text;
BEGIN
  SELECT id INTO v_pfa_account_id
  FROM public.pfa_accounts
  WHERE agency_id = p_agency_id AND is_active = true LIMIT 1;

  IF v_pfa_account_id IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No active PFA account.');
  END IF;

  SELECT t.telegram_user_id INTO v_peter_tg
  FROM public.team t
  WHERE t.first_name='Peter' AND t.last_name='Story' AND t.telegram_user_id IS NOT NULL LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT setting_value INTO v_shared_secret
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';

  FOR v_statement IN
    SELECT s.id, s.statement_period_start, s.statement_period_end, s.closing_balance
    FROM public.pfa_bank_statements s
    WHERE s.pfa_account_id = v_pfa_account_id
      AND NOT EXISTS (
        SELECT 1 FROM public.pfa_reconciliations r WHERE r.statement_id = s.id
      )
    ORDER BY s.statement_period_end
  LOOP
    v_processed_count := v_processed_count + 1;

    SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_sf_eft_total
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND transaction_type = 'State Farm EFT'
      AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    SELECT COALESCE(SUM(credit_amount), 0) INTO v_outstanding_deposits_total
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND credit_amount IS NOT NULL
      AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_checks_total
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND debit_amount IS NOT NULL
      AND transaction_type <> 'State Farm EFT'
      AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    SELECT COALESCE(SUM(debit_amount), 0) INTO v_current_bank_service_fees
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND transaction_type = 'Bank Service Fee'
      AND voided_at IS NULL
      AND cleared = true
      AND cleared_date >= v_statement.statement_period_start
      AND cleared_date <= v_statement.statement_period_end;

    SELECT r.prior_personal_funds, r.current_bank_service_fees INTO v_prev_recon
    FROM public.pfa_reconciliations r
    WHERE r.pfa_account_id = v_pfa_account_id
      AND r.statement_ending_date < v_statement.statement_period_end
    ORDER BY r.statement_ending_date DESC LIMIT 1;

    v_prior_personal_funds := COALESCE(v_prev_recon.prior_personal_funds, 0)
                              - COALESCE(v_prev_recon.current_bank_service_fees, 0);

    v_adjusted_statement_balance := v_statement.closing_balance
                                    - v_outstanding_checks_total
                                    - v_outstanding_sf_eft_total
                                    + v_outstanding_deposits_total
                                    + v_returned_checks_unreim;
    v_difference := v_adjusted_statement_balance - v_prior_personal_funds;

    INSERT INTO public.pfa_reconciliations (
      pfa_account_id, statement_id, statement_ending_date, statement_ending_balance,
      outstanding_checks_total, outstanding_sf_eft_total, outstanding_deposits_total,
      returned_checks_unreimbursed, adjusted_statement_balance,
      prior_personal_funds, current_bank_service_fees, difference_to_reconcile,
      explanation, reconciled_at
    ) VALUES (
      v_pfa_account_id, v_statement.id, v_statement.statement_period_end, v_statement.closing_balance,
      v_outstanding_checks_total, v_outstanding_sf_eft_total, v_outstanding_deposits_total,
      v_returned_checks_unreim, v_adjusted_statement_balance,
      v_prior_personal_funds, v_current_bank_service_fees, v_difference,
      'Auto-computed by pfa_monthly_reconciliation.',
      now()
    )
    RETURNING id INTO v_recon_id;

    IF abs(v_difference) < 0.005 AND v_shared_secret IS NOT NULL THEN
      PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '10000');
      PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '60000');
      BEGIN
        SELECT (extensions.http_post(
          'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/pfa-reconciliation-send',
          jsonb_build_object(
            'agency_id',         p_agency_id,
            'shared_secret',     v_shared_secret,
            'reconciliation_id', v_recon_id,
            'force',             false
          )::text,
          'application/json'
        )).content::jsonb INTO v_send_resp;
        v_send_ok := COALESCE((v_send_resp->>'ok')::boolean, false);
        v_send_status := COALESCE(v_send_resp->>'status', 'unknown');
      EXCEPTION WHEN OTHERS THEN
        v_send_ok := false;
        v_send_status := 'exception: ' || SQLERRM;
        v_send_resp := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;

      IF v_send_ok AND v_send_status = 'sent' THEN
        v_dm_text := format(
          E'✅ PFA reconciliation auto-sent\n\nStatement ending: %s\nDifference: $0.00 (clean)\nSent to peter.story.yrru@statefarm.com\n\nMessage ID: %s',
          to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
          COALESCE(v_send_resp->>'message_id', 'unknown')
        );
      ELSE
        v_alert_title := 'PFA reconciliation SEND FAILED for ' || to_char(v_statement.statement_period_end, 'FMMonth YYYY');
        v_alert_message := format('Reconciliation for %s computed clean ($0.00 diff) but auto-send failed: %s. Retry from Deposits → Reconciliations → Send to SF.',
          to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
          COALESCE(v_send_resp->>'error', v_send_status));
        INSERT INTO public.alerts (
          agency_id, alert_type, severity, title, message, module_reference,
          is_read, is_resolved, related_id, created_at
        ) VALUES (
          p_agency_id, 'pfa_reconciliation_send_failed', 'warning',
          v_alert_title, v_alert_message,
          'pfa_reconciliation:' || v_recon_id::text,
          false, false, v_recon_id, now()
        );
        v_dm_text := format(
          E'⚠️ PFA auto-send failed\n\nStatement ending: %s\nDifference: $0.00 (clean)\nSend error: %s\n\nRetry at https://newtworks.vercel.app/pfa (Deposits → Reconciliations → Send to SF).',
          to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
          COALESCE(v_send_resp->>'error', v_send_status)
        );
      END IF;

    ELSE
      v_alert_title := '⚠️ PFA reconciliation DISCREPANCY — ' || to_char(v_statement.statement_period_end, 'FMMonth YYYY');
      v_alert_message := format('The reconciliation for the PFA statement ending %s has a difference of $%s. Do NOT send to SF until reviewed. Open Deposits → Reconciliations and expand the row to see the waterfall + outstanding items.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_difference, 'FM999,999,990.00')));
      INSERT INTO public.alerts (
        agency_id, alert_type, severity, title, message, module_reference,
        is_read, is_resolved, related_id, created_at
      ) VALUES (
        p_agency_id, 'pfa_reconciliation_ready', 'warning',
        v_alert_title, v_alert_message,
        'pfa_reconciliation:' || v_recon_id::text,
        false, false, v_recon_id, now()
      );
      v_dm_text := format(E'⚠️ PFA reconciliation discrepancy\n\nStatement ending: %s\nClosing balance: $%s\nOutstanding SF EFTs: $%s\nOutstanding deposits: $%s\nAdjusted balance: $%s\nPrior personal funds: $%s\n\nDifference: $%s ❌\n\nReview at https://newtworks.vercel.app/pfa before sending.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_statement.closing_balance, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_sf_eft_total, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_deposits_total, 'FM999,999,990.00')),
        trim(to_char(v_adjusted_statement_balance, 'FM999,999,990.00')),
        trim(to_char(v_prior_personal_funds, 'FM999,999,990.00')),
        trim(to_char(v_difference, 'FM999,999,990.00')));
    END IF;

    BEGIN
      PERFORM public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'PFA recon % Telegram DM failed: %', v_recon_id, SQLERRM;
    END;

    v_results := v_results || jsonb_build_object(
      'reconciliation_id', v_recon_id,
      'statement_period_end', v_statement.statement_period_end,
      'adjusted_balance', v_adjusted_statement_balance,
      'difference', v_difference,
      'clean', (abs(v_difference) < 0.005),
      'auto_sent', COALESCE(v_send_ok AND v_send_status = 'sent', false)
    );
  END LOOP;

  IF v_processed_count = 0 THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No unreconciled statements.');
  END IF;

  RETURN jsonb_build_object(
    'records_processed', v_processed_count,
    'output_summary', format('Auto-computed %s reconciliation(s).', v_processed_count),
    'results', v_results
  );
END;
$function$;

-- 4h. quarter_close_prize_cart_and_leaderboards
CREATE OR REPLACE FUNCTION public.quarter_close_prize_cart_and_leaderboards(p_agency_id uuid, p_quarter_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_next_q_end          date;
  v_carried             int := 0;
  v_carried_value_total numeric := 0;
  v_smvc_annual         numeric := 0;
  v_scorecard_annual    numeric := 0;
  v_ot_basis_annual     numeric := 0;
  v_closing_qtr_wins    int := 0;
  v_pace                numeric := 0;
  v_rate                CONSTANT numeric := 0.01;
  v_next_budget         numeric := 0;
  v_available_budget    numeric := 0;
  v_pool_result         jsonb;
  v_audit_result        jsonb;
  v_result              jsonb;
  v_pending_id          uuid;
  v_peter_chat_id       bigint;
  v_telegram_text       text;
BEGIN
  v_next_q_end := p_quarter_ending_date + INTERVAL '13 weeks';

  WITH carried AS (
    INSERT INTO public.prize_cart (
      agency_id, quarter_ending_date, display_order,
      prize_description, prize_url, prize_value
    )
    SELECT agency_id, v_next_q_end, display_order,
           prize_description, prize_url, prize_value
    FROM public.prize_cart
    WHERE agency_id = p_agency_id
      AND quarter_ending_date = p_quarter_ending_date
      AND winner_team_member_id IS NULL
    RETURNING prize_value
  )
  SELECT COUNT(*), COALESCE(SUM(prize_value), 0)
  INTO v_carried, v_carried_value_total
  FROM carried;

  v_pool_result       := public.compute_pool_basis_and_envelope(p_agency_id, p_quarter_ending_date);
  v_smvc_annual       := COALESCE((v_pool_result->'basis'->>'on_time_smvc_dollars')::numeric, 0);
  v_scorecard_annual  := COALESCE((v_pool_result->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_ot_basis_annual   := v_smvc_annual + v_scorecard_annual;

  SELECT COUNT(*) INTO v_closing_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date > (p_quarter_ending_date - INTERVAL '13 weeks')
    AND week_ending_date <= p_quarter_ending_date
    AND won_the_week = true;

  v_pace        := LEAST(1.0, v_closing_qtr_wins::numeric / 13.0);
  v_next_budget := ROUND(v_rate * v_ot_basis_annual * v_pace, 2);

  INSERT INTO public.quarter_prize_budgets (agency_id, quarter_ending_date, budget_dollars, formula_note)
  VALUES (p_agency_id, v_next_q_end, v_next_budget,
          format('1%% × on-time (SMVC $%s + Scorecard $%s) × %s/13 weeks won = $%s',
                 v_smvc_annual::text, v_scorecard_annual::text, v_closing_qtr_wins::text, v_next_budget::text))
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET budget_dollars = EXCLUDED.budget_dollars,
        formula_note   = EXCLUDED.formula_note;

  v_available_budget := ROUND(v_next_budget - v_carried_value_total, 2);

  INSERT INTO public.pending_prize_research (
    agency_id, quarter_ending_date, available_budget_dollars,
    carried_prize_count, carried_prize_value_total, status, notes
  )
  VALUES (
    p_agency_id, v_next_q_end, v_available_budget,
    v_carried, v_carried_value_total, 'pending',
    format('Quarter closed %s. %s prizes carried ($%s total). Budget $%s (1%% × OT basis × %s/13 wins). Available for new prizes: $%s.',
           p_quarter_ending_date::text, v_carried, v_carried_value_total::text,
           v_next_budget::text, v_closing_qtr_wins::text, v_available_budget::text)
  )
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET available_budget_dollars = EXCLUDED.available_budget_dollars,
        carried_prize_count      = EXCLUDED.carried_prize_count,
        carried_prize_value_total= EXCLUDED.carried_prize_value_total,
        status                   = 'pending',
        updated_at               = now()
  RETURNING id INTO v_pending_id;

  BEGIN
    v_audit_result := public.audit_weekly_leaderboard_crossings(p_agency_id, p_quarter_ending_date);
  EXCEPTION WHEN OTHERS THEN
    v_audit_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE);
  END;

  INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
  VALUES (
    p_agency_id, 'system', 'prize_cart_refresh', 'medium',
    format('Prize cart refresh — $%s available (Q ending %s)',
           v_available_budget::text, to_char(v_next_q_end, 'YYYY-MM-DD')),
    format('Quarter closed. %s prizes carried ($%s). Budget $%s (%s/13 wins). Available for new prizes: $%s. '
           'Run Claude session with op-rule "Newtworks quarter-end prize cart research" to research + verify links + propose new items.',
           v_carried, v_carried_value_total::text, v_next_budget::text, v_closing_qtr_wins::text, v_available_budget::text),
    v_pending_id,
    false
  );

  -- swap: team_telegram_map.telegram_first/last_name → team.first_name/last_name
  SELECT telegram_user_id INTO v_peter_chat_id
  FROM public.team
  WHERE agency_id = p_agency_id
    AND first_name = 'Peter'
    AND last_name = 'Story'
    AND telegram_user_id IS NOT NULL
  LIMIT 1;

  IF v_peter_chat_id IS NOT NULL THEN
    v_telegram_text :=
      '🏆 Prize cart refresh ready' || chr(10) || chr(10) ||
      'Quarter closed: ' || p_quarter_ending_date::text || ' -> next quarter ends ' || v_next_q_end::text || chr(10) ||
      '• ' || v_carried::text || ' prizes carried ($' || v_carried_value_total::text || ' total value)' || chr(10) ||
      '• Closing quarter wins: ' || v_closing_qtr_wins::text || '/13 (pace ' || ROUND(v_pace, 4)::text || ')' || chr(10) ||
      '• Next quarter budget: $' || v_next_budget::text || chr(10) ||
      '• Available for new prizes: $' || v_available_budget::text || chr(10) || chr(10) ||
      'Start a Claude session and say "run prize cart research" — Claude will use the ' ||
      '"Newtworks quarter-end prize cart research" operational rule to verify all links ' ||
      'and propose new prizes within budget.';

    BEGIN
      PERFORM public.paper_newt_send_message(v_peter_chat_id, v_telegram_text, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
      VALUES (p_agency_id, 'system', 'prize_cart_refresh', 'medium',
              'Quarter-close nudge to Peter failed',
              format('Quarter=%s Error=%s', p_quarter_ending_date::text, SQLERRM),
              v_pending_id,
              false);
    END;
  ELSE
    INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
    VALUES (p_agency_id, 'system', 'prize_cart_refresh', 'medium',
            'Quarter-close nudge to Peter: no telegram_user_id on team row',
            format('No telegram_user_id found for Peter Story on team in agency %s. Quarter=%s.',
                   p_agency_id::text, p_quarter_ending_date::text),
            v_pending_id,
            false);
  END IF;

  v_result := jsonb_build_object(
    'quarter_ending_date',        p_quarter_ending_date,
    'next_quarter_ending_date',   v_next_q_end,
    'prizes_carried',             v_carried,
    'carried_value_total',        v_carried_value_total,
    'closing_qtr_wins',           v_closing_qtr_wins,
    'pace',                       ROUND(v_pace, 4),
    'rate_pct',                   v_rate,
    'ot_basis_annual',            v_ot_basis_annual,
    'next_quarter_budget_dollars',v_next_budget,
    'available_budget_dollars',   v_available_budget,
    'pending_prize_research_id',  v_pending_id,
    'leaderboard_audit_result',   v_audit_result,
    'ran_at',                     now()
  );

  RETURN v_result;
END;
$function$;

-- 4i. team_checkin_tag_missing (drops telegram_username fallback, uses first_name only since all values were NULL)
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb;
  v_checkin_type text;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_missing record;
  v_missing_tags text := '';
  v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0;
  v_is_recovery boolean := false;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_is_within_recovery_window(v_local_time)
        AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'tag_missing') THEN
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to tag');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  FOR v_missing IN
    SELECT et.team_id AS id, et.first_name
    FROM public.get_expected_teammates(p_agency_id, 'work_checkin') et
    LEFT JOIN public.team_checkins tc ON tc.team_id = et.team_id AND tc.agency_id = p_agency_id
      AND tc.checkin_date = v_today AND tc.checkin_type = v_checkin_type
    WHERE tc.id IS NULL
    ORDER BY et.first_name
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
  END LOOP;

  IF v_missing_count = 0 THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s tag-missing: silent (everyone already in)', v_checkin_type));
  END IF;

  v_text := '⏰ Still need numbers from: ' || trim(v_missing_tags);
  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET tag_missing_at = now(),
      tag_missing_message_id = v_message_id,
      tag_missing_team_ids = v_missing_ids,
      updated_at = now()
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object('records_processed', v_missing_count,
    'output_summary', format('%s tag-missing%s: %s pending',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END, v_missing_count));
END;
$function$;

-- 4j. time_clock_edit_notifications
CREATE OR REPLACE FUNCTION public.time_clock_edit_notifications(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_peter_chat_id bigint;
  v_pending_sent  int := 0;
  v_pending_fail  int := 0;
  v_resolved_sent int := 0;
  v_resolved_fail int := 0;
  v_resolved_skip int := 0;
  r_group         record;
  r_res           record;
  v_msg           text;
  v_resp          jsonb;
  v_type_label    text;
BEGIN
  SELECT t.telegram_user_id INTO v_peter_chat_id
    FROM public.team t
   WHERE t.agency_id = p_agency_id
     AND t.role_level = 'Owner'
     AND t.is_admin_backoffice = false
     AND COALESCE(t.is_excluded_pjsagencybot, false) = false
     AND t.telegram_user_id IS NOT NULL
   LIMIT 1;

  IF v_peter_chat_id IS NOT NULL THEN
    FOR r_group IN
      SELECT tcer.team_member_id, t.first_name, t.last_name,
             array_agg(tcer.id           ORDER BY tcer.submitted_at) AS request_ids,
             array_agg(tcer.edit_type    ORDER BY tcer.submitted_at) AS edit_types,
             array_agg(tcer.punch_date   ORDER BY tcer.submitted_at) AS punch_dates,
             array_agg(tcer.reason       ORDER BY tcer.submitted_at) AS reasons
        FROM public.time_clock_edit_requests tcer
        JOIN public.team t ON t.id = tcer.team_member_id
       WHERE tcer.agency_id = p_agency_id
         AND tcer.status = 'pending'
         AND tcer.telegram_notified_at IS NULL
       GROUP BY tcer.team_member_id, t.first_name, t.last_name
    LOOP
      v_msg := E'⏰ Time clock edit request'
            || CASE WHEN array_length(r_group.request_ids, 1) > 1
                    THEN 's (' || array_length(r_group.request_ids, 1) || ')' ELSE '' END
            || E' from ' || r_group.first_name || ' ' || r_group.last_name || E'\n';

      FOR i IN 1..array_length(r_group.request_ids, 1) LOOP
        v_type_label := CASE r_group.edit_types[i]
          WHEN 'missed_shift'     THEN 'Missed shift'
          WHEN 'missed_clock_in'  THEN 'Missed clock-in'
          WHEN 'missed_clock_out' THEN 'Missed clock-out'
          WHEN 'wrong_time'       THEN 'Wrong time'
          ELSE r_group.edit_types[i]
        END;
        v_msg := v_msg || E'\n• '
              || to_char(r_group.punch_dates[i], 'Dy Mon DD')
              || ' — ' || v_type_label
              || E'\n  "' || left(r_group.reasons[i], 140) || '"';
      END LOOP;

      v_msg := v_msg || E'\n\nReview in Time Clock → Admin.';
      v_resp := public.paper_newt_send_message(v_peter_chat_id, v_msg);

      IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
        UPDATE public.time_clock_edit_requests
           SET telegram_notified_at = now()
         WHERE id = ANY(r_group.request_ids);
        v_pending_sent := v_pending_sent + array_length(r_group.request_ids, 1);
      ELSE
        v_pending_fail := v_pending_fail + array_length(r_group.request_ids, 1);
      END IF;
    END LOOP;
  END IF;

  -- Resolved requests: read telegram_user_id directly off team, gated by is_excluded_pjsagencybot
  FOR r_res IN
    SELECT tcer.id, tcer.team_member_id, tcer.status, tcer.edit_type, tcer.punch_date, tcer.review_note,
           t.first_name,
           CASE WHEN COALESCE(t.is_excluded_pjsagencybot, false) = false
                THEN t.telegram_user_id
                ELSE NULL
           END AS telegram_user_id
      FROM public.time_clock_edit_requests tcer
      JOIN public.team t ON t.id = tcer.team_member_id
     WHERE tcer.agency_id = p_agency_id
       AND tcer.status IN ('approved','denied','cancelled')
       AND tcer.requester_notified_at IS NULL
     ORDER BY tcer.reviewed_at NULLS LAST
     LIMIT 20
  LOOP
    IF r_res.status = 'cancelled' THEN
      UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;
      v_resolved_skip := v_resolved_skip + 1;
      CONTINUE;
    END IF;

    IF r_res.telegram_user_id IS NULL THEN
      UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;
      v_resolved_skip := v_resolved_skip + 1;
      CONTINUE;
    END IF;

    v_type_label := CASE r_res.edit_type
      WHEN 'missed_shift'     THEN 'missed shift'
      WHEN 'missed_clock_in'  THEN 'missed clock-in'
      WHEN 'missed_clock_out' THEN 'missed clock-out'
      WHEN 'wrong_time'       THEN 'wrong time'
      ELSE r_res.edit_type
    END;

    IF r_res.status = 'approved' THEN
      v_msg := format(E'✅ %s, your time clock edit request was approved.\n\n%s · %s',
                      r_res.first_name, to_char(r_res.punch_date, 'Dy Mon DD'), v_type_label);
    ELSE
      v_msg := format(E'❌ %s, your time clock edit request was denied.\n\n%s · %s',
                      r_res.first_name, to_char(r_res.punch_date, 'Dy Mon DD'), v_type_label);
    END IF;

    IF r_res.review_note IS NOT NULL AND length(btrim(r_res.review_note)) > 0 THEN
      v_msg := v_msg || E'\n\nPeter: "' || r_res.review_note || '"';
    END IF;

    v_resp := public.telegram_send_message(r_res.telegram_user_id, v_msg);
    UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;

    IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
      v_resolved_sent := v_resolved_sent + 1;
    ELSE
      v_resolved_fail := v_resolved_fail + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'records_processed', v_pending_sent + v_resolved_sent + v_resolved_skip,
    'output_summary',    format('pending→paper_newt: %s sent / %s failed · resolved→pjsagencybot: %s sent / %s failed / %s skipped',
                                v_pending_sent, v_pending_fail, v_resolved_sent, v_resolved_fail, v_resolved_skip)
  );
END;
$function$;

-- 4k. try_send_weekly_cpr_recap
CREATE OR REPLACE FUNCTION public.try_send_weekly_cpr_recap()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '210000'
AS $function$
DECLARE
  v_agency_id      uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_now_ct         timestamp;
  v_hour_ct        int;
  v_dow            int;
  v_week_end       date;
  v_report         record;
  v_send_result    jsonb;
  v_recompute_res  jsonb;
  v_recompute_note text := '';
  v_ok             boolean;
  v_reason         text;
  v_recipe_id      uuid;
  v_day_label      text;
  v_retry_note     text;
  v_peter_chat     bigint;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'weekly_cpr_auto_send' LIMIT 1;

  v_now_ct  := (now() AT TIME ZONE 'America/Chicago');
  v_hour_ct := EXTRACT(HOUR FROM v_now_ct)::int;
  v_dow     := EXTRACT(DOW  FROM v_now_ct)::int;

  IF v_hour_ct <> 6 THEN
    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
      VALUES (v_agency_id, v_recipe_id, now(), 'success',
              format('Skipped: wrong-DST cron fire (intended 6 AM CT, got hour %s)', v_hour_ct));
    END IF;
    RETURN jsonb_build_object('skipped', true, 'reason', 'wrong_dst_hour', 'hour_ct', v_hour_ct);
  END IF;

  v_week_end := (v_now_ct::date) - ((v_dow + 1) % 7);

  v_day_label  := CASE v_dow WHEN 6 THEN 'Sat' WHEN 0 THEN 'Sun' WHEN 1 THEN 'Mon'
                             ELSE 'Day' || v_dow::text END;
  v_retry_note := CASE v_dow WHEN 6 THEN ' Sun + Mon backups will retry.'
                             WHEN 0 THEN ' Mon backup will retry.'
                             WHEN 1 THEN ' No further auto-retry — manual send needed.'
                             ELSE '' END;

  SELECT * INTO v_report FROM public.weekly_cpr_reports
   WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;

  IF NOT FOUND THEN
    v_ok := false;
    v_reason := 'No weekly_cpr_reports row for week ending ' || v_week_end::text;
  ELSIF v_report.sent_to_team_at IS NOT NULL THEN
    v_ok := false;
    v_reason := 'already_sent at ' || v_report.sent_to_team_at::text;
  ELSIF COALESCE(v_report.send_attempt_count, 0) >= 3 THEN
    v_ok := false;
    v_reason := 'attempt_cap_reached (' || v_report.send_attempt_count || ' of 3)';
  ELSIF v_report.send_dispatched_at IS NOT NULL
        AND v_report.send_dispatched_at > now() - INTERVAL '90 minutes' THEN
    v_ok := false;
    v_reason := 'recent_dispatch_in_flight since ' || v_report.send_dispatched_at::text;
  ELSIF v_report.opener_text IS NULL OR length(btrim(v_report.opener_text)) < 100 THEN
    v_ok := false;
    v_reason := 'opener_not_ready (chars=' ||
                COALESCE(length(btrim(v_report.opener_text)), 0) || ', need >=100)';
  ELSIF v_report.looking_next_week_text IS NULL OR length(btrim(v_report.looking_next_week_text)) < 50 THEN
    v_ok := false;
    v_reason := 'looking_ahead_not_ready (chars=' ||
                COALESCE(length(btrim(v_report.looking_next_week_text)), 0) || ', need >=50)';
  ELSE
    v_ok := true;
  END IF;

  IF NOT v_ok THEN
    SELECT t.telegram_user_id INTO v_peter_chat
      FROM public.team t
     WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner'
       AND t.is_admin_backoffice = false AND coalesce(t.is_excluded_pjsagencybot, false) = false
       AND t.telegram_user_id IS NOT NULL
     LIMIT 1;

    IF v_peter_chat IS NOT NULL AND v_reason NOT LIKE 'already_sent%'
       AND v_reason NOT LIKE 'recent_dispatch%' THEN
      BEGIN
        PERFORM public.paper_newt_send_message(v_peter_chat,
          format(E'🟡 CPR %s send skipped: %s.%s',
                 v_day_label, v_reason, v_retry_note));
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;

    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
      VALUES (v_agency_id, v_recipe_id, now(), 'success',
              format('Skipped %s: %s', v_day_label, v_reason));
    END IF;

    RETURN jsonb_build_object('skipped', true, 'reason', v_reason, 'day', v_day_label,
                              'week_ending_date', v_week_end);
  END IF;

  BEGIN
    v_recompute_res := public.write_weekly_comp_v2(v_agency_id, v_week_end);
    v_recompute_note := format(' recompute_ok(rows=%s)', v_recompute_res->>'rows_updated');
  EXCEPTION WHEN OTHERS THEN
    v_recompute_note := format(' recompute_failed(%s)', SQLERRM);
  END;

  v_send_result := public.send_weekly_cpr_recap(v_agency_id, v_week_end);

  IF v_recipe_id IS NOT NULL THEN
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
    VALUES (v_agency_id, v_recipe_id, now(),
            CASE WHEN (v_send_result->>'success')::boolean THEN 'success' ELSE 'error' END,
            format('%s auto-send dispatched.%s verify_pending_cpr_sends will confirm. Result: %s',
                   v_day_label, v_recompute_note, v_send_result::text));
  END IF;

  RETURN jsonb_build_object('day', v_day_label, 'week_ending_date', v_week_end,
                            'recompute_note', v_recompute_note,
                            'send_result', v_send_result);
END;
$function$;

-- 4l. verify_pending_cpr_sends
CREATE OR REPLACE FUNCTION public.verify_pending_cpr_sends()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_agency_id       uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_recipe_id       uuid;
  v_run_started     timestamptz := now();
  v_report          record;
  v_send_resp       record;
  v_verify_resp     record;
  v_content_jsonb   jsonb;
  v_gmail_msg_id    text;
  v_label_ids       jsonb;
  v_gmail_ts        timestamptz;
  v_verify_req_id   bigint;
  v_api_key         text;
  v_composio_user   text;
  v_conn_acct       text;
  v_confirmed       int := 0;
  v_dispatched_verify int := 0;
  v_reset_error     int := 0;
  v_reset_stale     int := 0;
  v_escalated       int := 0;
  v_still_pending   int := 0;
  v_details         jsonb := '[]'::jsonb;
  v_peter_chat      bigint;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'verify_pending_cpr_sends' LIMIT 1;

  IF NOT EXISTS (
    SELECT 1 FROM public.weekly_cpr_reports
    WHERE agency_id = v_agency_id
      AND sent_to_team_at IS NULL
      AND send_dispatched_at IS NOT NULL
  ) THEN
    RETURN jsonb_build_object('pending', 0, 'note', 'No pending sends to verify.');
  END IF;

  SELECT setting_value INTO v_api_key
    FROM public.settings WHERE agency_id = v_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_composio_user
    FROM public.settings WHERE agency_id = v_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_conn_acct
    FROM public.settings WHERE agency_id = v_agency_id AND setting_key = 'composio_gmail_account_id';

  SELECT t.telegram_user_id INTO v_peter_chat
    FROM public.team t
   WHERE t.agency_id = v_agency_id
     AND t.role_level = 'Owner'
     AND t.is_admin_backoffice = false
     AND coalesce(t.is_excluded_pjsagencybot, false) = false
     AND t.telegram_user_id IS NOT NULL
   LIMIT 1;

  FOR v_report IN
    SELECT * FROM public.weekly_cpr_reports
     WHERE agency_id = v_agency_id
       AND sent_to_team_at IS NULL
       AND send_dispatched_at IS NOT NULL
     ORDER BY send_dispatched_at
  LOOP
    IF v_report.gmail_message_id IS NULL THEN
      SELECT id, status_code, content, error_msg, created INTO v_send_resp
        FROM net._http_response WHERE id = v_report.send_request_id;

      IF v_send_resp.id IS NULL THEN
        IF v_report.send_dispatched_at < now() - INTERVAL '10 minutes' THEN
          UPDATE public.weekly_cpr_reports
             SET send_dispatched_at = NULL, send_request_id = NULL
           WHERE id = v_report.id;
          v_reset_stale := v_reset_stale + 1;
          v_details := v_details || jsonb_build_object(
            'week_ending_date', v_report.week_ending_date,
            'phase', 1, 'action', 'reset_stale_no_response',
            'attempt', v_report.send_attempt_count);
        ELSE
          v_still_pending := v_still_pending + 1;
        END IF;

      ELSIF v_send_resp.status_code BETWEEN 200 AND 299 THEN
        BEGIN
          v_content_jsonb := v_send_resp.content::jsonb;
        EXCEPTION WHEN OTHERS THEN
          v_content_jsonb := NULL;
        END;

        v_gmail_msg_id := v_content_jsonb #>> '{data,response_data,id}';

        IF v_gmail_msg_id IS NULL OR btrim(v_gmail_msg_id) = '' THEN
          UPDATE public.weekly_cpr_reports
             SET send_dispatched_at = NULL, send_request_id = NULL
           WHERE id = v_report.id;
          v_reset_error := v_reset_error + 1;
          v_details := v_details || jsonb_build_object(
            'week_ending_date', v_report.week_ending_date,
            'phase', 1, 'action', 'reset_no_msgid_in_2xx_body',
            'body', left(coalesce(v_send_resp.content, ''), 300));
        ELSE
          SELECT net.http_post(
            url     := 'https://backend.composio.dev/api/v3/tools/execute/GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID',
            headers := jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
            body    := jsonb_build_object(
              'user_id', v_composio_user,
              'connected_account_id', v_conn_acct,
              'arguments', jsonb_build_object(
                'message_id', v_gmail_msg_id,
                'user_id', 'me',
                'format', 'metadata'
              )
            ),
            timeout_milliseconds := 60000
          ) INTO v_verify_req_id;

          UPDATE public.weekly_cpr_reports
             SET gmail_message_id       = v_gmail_msg_id,
                 gmail_verify_request_id = v_verify_req_id
           WHERE id = v_report.id;

          v_dispatched_verify := v_dispatched_verify + 1;
          v_details := v_details || jsonb_build_object(
            'week_ending_date', v_report.week_ending_date,
            'phase', 1, 'action', 'msgid_captured_verify_fired',
            'gmail_message_id', v_gmail_msg_id,
            'verify_request_id', v_verify_req_id);
        END IF;

      ELSE
        UPDATE public.weekly_cpr_reports
           SET send_dispatched_at = NULL, send_request_id = NULL
         WHERE id = v_report.id;
        v_reset_error := v_reset_error + 1;
        v_details := v_details || jsonb_build_object(
          'week_ending_date', v_report.week_ending_date,
          'phase', 1, 'action', 'reset_send_error',
          'status_code', v_send_resp.status_code,
          'error_msg', v_send_resp.error_msg,
          'body', left(coalesce(v_send_resp.content, ''), 300));
      END IF;

    ELSE
      SELECT id, status_code, content, error_msg, created INTO v_verify_resp
        FROM net._http_response WHERE id = v_report.gmail_verify_request_id;

      IF v_verify_resp.id IS NULL THEN
        IF v_report.send_dispatched_at < now() - INTERVAL '2 hours' THEN
          UPDATE public.weekly_cpr_reports
             SET send_dispatched_at = NULL, send_request_id = NULL,
                 gmail_message_id = NULL, gmail_verify_request_id = NULL
           WHERE id = v_report.id;
          v_reset_stale := v_reset_stale + 1;
          v_details := v_details || jsonb_build_object(
            'week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'reset_verify_stale',
            'attempt', v_report.send_attempt_count);
        ELSE
          v_still_pending := v_still_pending + 1;
        END IF;

      ELSIF v_verify_resp.status_code BETWEEN 200 AND 299 THEN
        BEGIN
          v_content_jsonb := v_verify_resp.content::jsonb;
        EXCEPTION WHEN OTHERS THEN
          v_content_jsonb := NULL;
        END;

        v_label_ids := v_content_jsonb #> '{data,labelIds}';

        BEGIN
          v_gmail_ts := (v_content_jsonb #>> '{data,messageTimestamp}')::timestamptz;
        EXCEPTION WHEN OTHERS THEN
          v_gmail_ts := NULL;
        END;

        IF v_label_ids IS NOT NULL AND v_label_ids @> '["SENT"]'::jsonb THEN
          UPDATE public.weekly_cpr_reports
             SET sent_to_team_at   = COALESCE(v_gmail_ts, v_verify_resp.created, now()),
                 gmail_verified_at = now()
           WHERE id = v_report.id;
          v_confirmed := v_confirmed + 1;
          v_details := v_details || jsonb_build_object(
            'week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'gmail_confirmed_sent',
            'gmail_message_id', v_report.gmail_message_id,
            'gmail_message_timestamp', v_gmail_ts,
            'labelIds', v_label_ids);
        ELSE
          UPDATE public.weekly_cpr_reports
             SET gmail_message_id = NULL, gmail_verify_request_id = NULL,
                 send_dispatched_at = NULL, send_request_id = NULL
           WHERE id = v_report.id;
          v_reset_error := v_reset_error + 1;
          v_details := v_details || jsonb_build_object(
            'week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'reset_no_sent_label',
            'labelIds', v_label_ids);
        END IF;

      ELSE
        UPDATE public.weekly_cpr_reports
           SET gmail_message_id = NULL, gmail_verify_request_id = NULL,
               send_dispatched_at = NULL, send_request_id = NULL
         WHERE id = v_report.id;
        v_reset_error := v_reset_error + 1;
        v_details := v_details || jsonb_build_object(
          'week_ending_date', v_report.week_ending_date,
          'phase', 2, 'action', 'reset_gmail_fetch_error',
          'status_code', v_verify_resp.status_code,
          'error_msg', v_verify_resp.error_msg,
          'body', left(coalesce(v_verify_resp.content, ''), 300));
      END IF;
    END IF;
  END LOOP;

  IF v_peter_chat IS NOT NULL THEN
    FOR v_report IN
      SELECT * FROM public.weekly_cpr_reports
       WHERE agency_id = v_agency_id
         AND sent_to_team_at IS NULL
         AND COALESCE(send_attempt_count, 0) >= 3
         AND escalation_alerted_at IS NULL
         AND week_ending_date >= CURRENT_DATE - INTERVAL '14 days'
    LOOP
      BEGIN
        PERFORM public.paper_newt_send_message(v_peter_chat,
          format(E'🔴🔴🔴 CPR RECAP — WEEK %s\nSend attempts exhausted (%s of 3). No Gmail confirmation.\nManual send required. Consider: SELECT public.send_weekly_cpr_recap(''%s''::uuid, ''%s''::date) after resetting send_attempt_count.',
                 v_report.week_ending_date, v_report.send_attempt_count,
                 v_agency_id, v_report.week_ending_date));
        UPDATE public.weekly_cpr_reports
           SET escalation_alerted_at = now()
         WHERE id = v_report.id;
        v_escalated := v_escalated + 1;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END LOOP;
  END IF;

  IF (v_reset_error + v_reset_stale) > 0 AND v_peter_chat IS NOT NULL THEN
    BEGIN
      PERFORM public.paper_newt_send_message(v_peter_chat,
        format(E'🟡 CPR verify: %s errors / %s stale reset\n\n%s',
               v_reset_error, v_reset_stale, left(v_details::text, 1000)));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;

  IF v_recipe_id IS NOT NULL AND (v_confirmed + v_dispatched_verify + v_reset_error + v_reset_stale + v_escalated) > 0 THEN
    INSERT INTO public.automation_run_log
      (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
    VALUES
      (v_agency_id, v_recipe_id, v_run_started,
       CASE WHEN (v_reset_error + v_reset_stale + v_escalated) > 0 THEN 'partial' ELSE 'success' END,
       v_confirmed + v_dispatched_verify + v_reset_error + v_reset_stale + v_escalated,
       jsonb_build_object(
         'confirmed', v_confirmed,
         'verify_dispatched', v_dispatched_verify,
         'still_pending', v_still_pending,
         'reset_error', v_reset_error,
         'reset_stale', v_reset_stale,
         'escalated', v_escalated,
         'details', v_details
       )::text,
       EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  END IF;

  RETURN jsonb_build_object(
    'confirmed', v_confirmed,
    'verify_dispatched', v_dispatched_verify,
    'still_pending', v_still_pending,
    'reset_error', v_reset_error,
    'reset_stale', v_reset_stale,
    'escalated', v_escalated,
    'details', v_details
  );
END;
$function$;

-- Step 5: Drop team_telegram_map (RLS policy auto-drops)
DROP TABLE public.team_telegram_map;
