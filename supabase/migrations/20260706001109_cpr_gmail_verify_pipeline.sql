-- Two-phase Gmail-authoritative verify pipeline for weekly CPR sends.
-- Phase 1: after send fires, parse Gmail messageId from Composio send response, then fire an independent
--          Gmail fetch-by-messageId lookup via Composio GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID.
-- Phase 2: read that fetch response; if labelIds contains 'SENT', stamp sent_to_team_at from Gmail's
--          internalDate. Otherwise treat as unverified and let 6 AM retry.
-- Replaces finalize_pending_cpr_sends. Every 15 min via pg_cron, state-bounded (no-op when nothing pending).

-- 1. Schema additions
ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS gmail_message_id       text,
  ADD COLUMN IF NOT EXISTS gmail_verify_request_id bigint,
  ADD COLUMN IF NOT EXISTS gmail_verified_at      timestamptz,
  ADD COLUMN IF NOT EXISTS send_attempt_count     int DEFAULT 0,
  ADD COLUMN IF NOT EXISTS escalation_alerted_at  timestamptz;

-- 2. Rewrite send_weekly_cpr_recap: add 90-min recent-dispatch guard, attempt cap, increment counter,
--    clear prior verify state before re-firing.
CREATE OR REPLACE FUNCTION public.send_weekly_cpr_recap(p_agency_id uuid, p_week_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_report                  record;
  v_html                    text;
  v_api_key                 text;
  v_user_id                 text;
  v_connected_account_id    text;
  v_subject                 text;
  v_week_start              date := p_week_ending_date - 6;
  v_start_mon               text;
  v_end_mon                 text;
  v_start_day               text;
  v_end_day                 text;
  v_subject_dates           text;
  v_request_id              bigint;
  v_recipients_to           text[];
  v_primary_to              text;
  v_extra_to                text[];
BEGIN
  SELECT * INTO v_report FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'No weekly_cpr_reports row exists for this week.');
  END IF;

  IF v_report.sent_to_team_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Already Gmail-confirmed at ' || v_report.sent_to_team_at::text);
  END IF;

  IF COALESCE(v_report.send_attempt_count, 0) >= 3 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Attempt cap reached (%s of 3). Manual send required — clear send_attempt_count to reset.',
                      v_report.send_attempt_count)
    );
  END IF;

  IF v_report.send_dispatched_at IS NOT NULL
     AND v_report.send_dispatched_at > now() - INTERVAL '90 minutes' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Recent dispatch within 90 min at ' || v_report.send_dispatched_at::text ||
               '. verify_pending_cpr_sends is still working on it. Wait or clear send_dispatched_at to force retry.'
    );
  END IF;

  IF v_report.opener_text IS NULL OR btrim(v_report.opener_text) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Opener text is empty.');
  END IF;

  IF v_report.looking_next_week_text IS NULL OR btrim(v_report.looking_next_week_text) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', '"Looking at next week" text is empty.');
  END IF;

  SELECT setting_value INTO v_api_key
    FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_user_id
    FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_connected_account_id
    FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_gmail_account_id';

  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Composio Gmail config missing in settings');
  END IF;

  SELECT array_agg(email_sf ORDER BY
                   CASE WHEN role_level = 'Owner' THEN 1 ELSE 0 END,
                   hire_date ASC NULLS LAST, last_name)
    INTO v_recipients_to
  FROM public.team
  WHERE agency_id   = p_agency_id
    AND category    = 'agency'
    AND is_active   = true
    AND is_admin_backoffice = false
    AND archived_at IS NULL
    AND email_sf    IS NOT NULL
    AND btrim(email_sf) <> '';

  IF v_recipients_to IS NULL OR array_length(v_recipients_to, 1) IS NULL OR array_length(v_recipients_to, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'No active agency team members with SF emails found in team table');
  END IF;

  v_primary_to := v_recipients_to[1];
  IF array_length(v_recipients_to, 1) > 1 THEN
    v_extra_to := v_recipients_to[2:];
  ELSE
    v_extra_to := ARRAY[]::text[];
  END IF;

  v_start_mon := upper(to_char(v_week_start,       'Mon'));
  v_end_mon   := upper(to_char(p_week_ending_date, 'Mon'));
  v_start_day := to_char(v_week_start,       'FMDD');
  v_end_day   := to_char(p_week_ending_date, 'FMDD');
  IF v_start_mon = v_end_mon THEN
    v_subject_dates := v_start_mon || ' ' || v_start_day || '-' || v_end_day;
  ELSE
    v_subject_dates := v_start_mon || ' ' || v_start_day || ' - ' || v_end_mon || ' ' || v_end_day;
  END IF;

  v_subject := E'\xF0\x9F\x93\x8A CPR RECAP \xE2\x80\x94 WEEK OF ' || v_subject_dates;
  v_html := public.compose_weekly_cpr_html(p_agency_id, p_week_ending_date);

  UPDATE public.weekly_cpr_reports
     SET send_dispatched_at     = now(),
         send_attempt_count     = COALESCE(send_attempt_count, 0) + 1,
         gmail_message_id       = NULL,
         gmail_verify_request_id = NULL,
         send_request_id        = NULL
   WHERE id = v_report.id;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/GMAIL_SEND_EMAIL',
    headers := jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'user_id', v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments', jsonb_build_object(
        'recipient_email', v_primary_to,
        'extra_recipients', to_jsonb(v_extra_to),
        'subject', v_subject,
        'body', v_html,
        'is_html', true
      )
    ),
    timeout_milliseconds := 180000
  ) INTO v_request_id;

  UPDATE public.weekly_cpr_reports SET send_request_id = v_request_id WHERE id = v_report.id;

  RETURN jsonb_build_object(
    'success', true,
    'status', 'pending',
    'request_id', v_request_id,
    'attempt', COALESCE(v_report.send_attempt_count, 0) + 1,
    'subject', v_subject,
    'recipients', v_recipients_to,
    'note', 'Dispatched to Composio. verify_pending_cpr_sends will confirm via Gmail lookup.'
  );
END;
$function$;

-- 3. Drop old finalize function
DROP FUNCTION IF EXISTS public.finalize_pending_cpr_sends();

-- 4. New verify_pending_cpr_sends: two-phase Gmail-authoritative verify.
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
  v_gmail_dt_epoch  bigint;
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

  SELECT ttm.telegram_user_id INTO v_peter_chat
    FROM public.team_telegram_map ttm
    JOIN public.team t ON t.id = ttm.team_id
   WHERE t.agency_id = v_agency_id
     AND t.role_level = 'Owner'
     AND t.is_admin_backoffice = false
     AND coalesce(ttm.is_excluded, false) = false
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

        v_label_ids := v_content_jsonb #> '{data,response_data,labelIds}';
        v_gmail_dt_epoch := (v_content_jsonb #>> '{data,response_data,internalDate}')::bigint;

        IF v_label_ids IS NOT NULL AND v_label_ids @> '["SENT"]'::jsonb THEN
          UPDATE public.weekly_cpr_reports
             SET sent_to_team_at   = COALESCE(
                                       to_timestamp(v_gmail_dt_epoch / 1000.0),
                                       v_verify_resp.created,
                                       now()),
                 gmail_verified_at = now()
           WHERE id = v_report.id;
          v_confirmed := v_confirmed + 1;
          v_details := v_details || jsonb_build_object(
            'week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'gmail_confirmed_sent',
            'gmail_message_id', v_report.gmail_message_id,
            'gmail_internal_date', v_gmail_dt_epoch,
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

-- 5. Tighten try_send_weekly_cpr_recap: add attempt cap + 90-min recent-dispatch guard.
--    Ready check now uses sent_to_team_at IS NULL (verify-authoritative).
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
    SELECT ttm.telegram_user_id INTO v_peter_chat
      FROM public.team_telegram_map ttm
      JOIN public.team t ON t.id = ttm.team_id
     WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner'
       AND t.is_admin_backoffice = false AND coalesce(ttm.is_excluded, false) = false
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

  v_send_result := public.send_weekly_cpr_recap(v_agency_id, v_week_end);

  IF v_recipe_id IS NOT NULL THEN
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
    VALUES (v_agency_id, v_recipe_id, now(),
            CASE WHEN (v_send_result->>'success')::boolean THEN 'success' ELSE 'error' END,
            format('%s auto-send dispatched. verify_pending_cpr_sends will confirm. Result: %s',
                   v_day_label, v_send_result::text));
  END IF;

  RETURN jsonb_build_object('day', v_day_label, 'week_ending_date', v_week_end,
                            'send_result', v_send_result);
END;
$function$;

-- 6. pg_cron: unschedule finalize, schedule verify at 15-min cadence
DO $outer$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'finalize_pending_cpr_sends') THEN
    PERFORM cron.unschedule('finalize_pending_cpr_sends');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'verify_pending_cpr_sends') THEN
    PERFORM cron.schedule(
      'verify_pending_cpr_sends',
      '*/15 * * * *',
      $cron$ SELECT public.verify_pending_cpr_sends(); $cron$
    );
  END IF;
END $outer$;

-- 7. Rename recipe row + update description
UPDATE public.automation_recipes
   SET recipe_name        = 'verify_pending_cpr_sends',
       internal_handler   = 'verify_pending_cpr_sends',
       recipe_description = 'Every 15 min via pg_cron. State-bounded: exits fast when no weekly_cpr_reports rows have dispatch pending. Two-phase Gmail-authoritative verify: phase 1 reads Composio send response from net._http_response, parses Gmail messageId, fires independent GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID lookup. Phase 2 reads that response, checks labelIds for SENT, stamps sent_to_team_at from Gmail internalDate. Clears state and Telegram-alerts on 4xx/5xx or stale (>10min send / >2hr verify). Escalates to hard Telegram when send_attempt_count >= 3 with no confirmation (once per row via escalation_alerted_at).'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND recipe_name = 'finalize_pending_cpr_sends';
