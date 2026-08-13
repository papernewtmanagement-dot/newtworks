-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-25 01:05:49 UTC (ledger name: cpr_recap_capture_rfc_message_id) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260725010549.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Capture the RFC-2822 Message-Id header on every CPR RECAP send so that
-- teammate replies (In-Reply-To carries the RFC id, NOT Gmail's internal id)
-- can be routed back to the correct week by wrapup_ingest.
--
-- Helper: extract Message-Id from a GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID response
-- (case-insensitive header match; strips the surrounding <> pair). Returns
-- NULL if no header found.
CREATE OR REPLACE FUNCTION public.extract_rfc_message_id(p_content jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT btrim(h->>'value', '<>')
    FROM jsonb_array_elements(p_content #> '{data,payload,headers}') h
   WHERE lower(h->>'name') = 'message-id'
   LIMIT 1;
$$;

-- Replace verify_pending_cpr_sends. Only Phase 2 confirmed-sent branch changes:
-- when the verify response confirms the SENT label, ALSO write
-- cpr_recap_message_id_rfc from the payload headers. Everything else
-- (attempt counter, escalation, retry logic) is preserved verbatim.
CREATE OR REPLACE FUNCTION public.verify_pending_cpr_sends()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_recipe_id uuid; v_run_started timestamptz := now();
  v_report record; v_send_resp record; v_verify_resp record; v_content_jsonb jsonb;
  v_gmail_msg_id text; v_label_ids jsonb; v_gmail_ts timestamptz;
  v_verify_req_id bigint; v_api_key text; v_composio_user text; v_conn_acct text;
  v_confirmed int := 0; v_dispatched_verify int := 0; v_reset_error int := 0;
  v_reset_stale int := 0; v_escalated int := 0; v_still_pending int := 0;
  v_details jsonb := '[]'::jsonb; v_peter_chat bigint;
  v_rfc_msg_id text;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'verify_pending_cpr_sends' LIMIT 1;

  IF NOT EXISTS (SELECT 1 FROM public.weekly_cpr_reports
    WHERE agency_id = v_agency_id AND sent_to_team_at IS NULL AND send_dispatched_at IS NOT NULL) THEN
    RETURN jsonb_build_object('pending', 0, 'note', 'No pending sends to verify.');
  END IF;

  SELECT setting_value INTO v_api_key FROM public.settings
   WHERE agency_id = v_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_composio_user FROM public.settings
   WHERE agency_id = v_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_conn_acct FROM public.settings
   WHERE agency_id = v_agency_id AND setting_key = 'composio_gmail_account_id';

  SELECT t.telegram_user_id INTO v_peter_chat FROM public.team t
   WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner'
     AND t.is_admin_backoffice = false AND coalesce(t.is_excluded_pjsagencybot, false) = false
     AND t.telegram_user_id IS NOT NULL LIMIT 1;

  FOR v_report IN
    SELECT * FROM public.weekly_cpr_reports
     WHERE agency_id = v_agency_id AND sent_to_team_at IS NULL AND send_dispatched_at IS NOT NULL
     ORDER BY send_dispatched_at
  LOOP
    IF v_report.gmail_message_id IS NULL THEN
      SELECT id, status_code, content, error_msg, created INTO v_send_resp
        FROM net._http_response WHERE id = v_report.send_request_id;

      IF v_send_resp.id IS NULL THEN
        IF v_report.send_dispatched_at < now() - INTERVAL '10 minutes' THEN
          UPDATE public.weekly_cpr_reports SET send_dispatched_at = NULL, send_request_id = NULL WHERE id = v_report.id;
          v_reset_stale := v_reset_stale + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 1, 'action', 'reset_stale_no_response', 'attempt', v_report.send_attempt_count);
        ELSE v_still_pending := v_still_pending + 1; END IF;

      ELSIF v_send_resp.status_code BETWEEN 200 AND 299 THEN
        BEGIN v_content_jsonb := v_send_resp.content::jsonb;
        EXCEPTION WHEN OTHERS THEN v_content_jsonb := NULL; END;

        v_gmail_msg_id := v_content_jsonb #>> '{data,response_data,id}';

        IF v_gmail_msg_id IS NULL OR btrim(v_gmail_msg_id) = '' THEN
          UPDATE public.weekly_cpr_reports SET send_dispatched_at = NULL, send_request_id = NULL WHERE id = v_report.id;
          v_reset_error := v_reset_error + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 1, 'action', 'reset_no_msgid_in_2xx_body',
            'body', left(coalesce(v_send_resp.content, ''), 300));
        ELSE
          SELECT net.http_post(
            url := 'https://backend.composio.dev/api/v3/tools/execute/GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID',
            headers := jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
            body := jsonb_build_object('user_id', v_composio_user, 'connected_account_id', v_conn_acct,
              'arguments', jsonb_build_object('message_id', v_gmail_msg_id, 'user_id', 'me', 'format', 'metadata')),
            timeout_milliseconds := 60000
          ) INTO v_verify_req_id;

          UPDATE public.weekly_cpr_reports
             SET gmail_message_id = v_gmail_msg_id, gmail_verify_request_id = v_verify_req_id
           WHERE id = v_report.id;

          v_dispatched_verify := v_dispatched_verify + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 1, 'action', 'msgid_captured_verify_fired',
            'gmail_message_id', v_gmail_msg_id, 'verify_request_id', v_verify_req_id);
        END IF;

      ELSE
        UPDATE public.weekly_cpr_reports SET send_dispatched_at = NULL, send_request_id = NULL WHERE id = v_report.id;
        v_reset_error := v_reset_error + 1;
        v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
          'phase', 1, 'action', 'reset_send_error',
          'status_code', v_send_resp.status_code, 'error_msg', v_send_resp.error_msg,
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
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'reset_verify_stale', 'attempt', v_report.send_attempt_count);
        ELSE v_still_pending := v_still_pending + 1; END IF;

      ELSIF v_verify_resp.status_code BETWEEN 200 AND 299 THEN
        BEGIN v_content_jsonb := v_verify_resp.content::jsonb;
        EXCEPTION WHEN OTHERS THEN v_content_jsonb := NULL; END;

        v_label_ids := v_content_jsonb #> '{data,labelIds}';

        BEGIN v_gmail_ts := (v_content_jsonb #>> '{data,messageTimestamp}')::timestamptz;
        EXCEPTION WHEN OTHERS THEN v_gmail_ts := NULL; END;

        IF v_label_ids IS NOT NULL AND v_label_ids @> '["SENT"]'::jsonb THEN
          -- NEW: capture RFC-2822 Message-Id header for future reply routing
          BEGIN v_rfc_msg_id := public.extract_rfc_message_id(v_content_jsonb);
          EXCEPTION WHEN OTHERS THEN v_rfc_msg_id := NULL; END;

          UPDATE public.weekly_cpr_reports
             SET sent_to_team_at = COALESCE(v_gmail_ts, v_verify_resp.created, now()),
                 gmail_verified_at = now(),
                 cpr_recap_message_id_rfc = v_rfc_msg_id
           WHERE id = v_report.id;
          v_confirmed := v_confirmed + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'gmail_confirmed_sent',
            'gmail_message_id', v_report.gmail_message_id,
            'gmail_message_timestamp', v_gmail_ts, 'labelIds', v_label_ids,
            'cpr_recap_message_id_rfc', v_rfc_msg_id);
        ELSE
          UPDATE public.weekly_cpr_reports
             SET gmail_message_id = NULL, gmail_verify_request_id = NULL,
                 send_dispatched_at = NULL, send_request_id = NULL
           WHERE id = v_report.id;
          v_reset_error := v_reset_error + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'reset_no_sent_label', 'labelIds', v_label_ids);
        END IF;

      ELSE
        UPDATE public.weekly_cpr_reports
           SET gmail_message_id = NULL, gmail_verify_request_id = NULL,
               send_dispatched_at = NULL, send_request_id = NULL
         WHERE id = v_report.id;
        v_reset_error := v_reset_error + 1;
        v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
          'phase', 2, 'action', 'reset_gmail_fetch_error',
          'status_code', v_verify_resp.status_code, 'error_msg', v_verify_resp.error_msg,
          'body', left(coalesce(v_verify_resp.content, ''), 300));
      END IF;
    END IF;
  END LOOP;

  IF v_peter_chat IS NOT NULL THEN
    FOR v_report IN
      SELECT * FROM public.weekly_cpr_reports
       WHERE agency_id = v_agency_id AND sent_to_team_at IS NULL
         AND COALESCE(send_attempt_count, 0) >= 3
         AND escalation_alerted_at IS NULL
         AND week_ending_date >= CURRENT_DATE - INTERVAL '14 days'
    LOOP
      BEGIN
        PERFORM public.paper_newt_send_message(v_peter_chat,
          format(E'🔴🔴🔴 CPR RECAP — WEEK %s\nSend attempts exhausted (%s of 3). No Gmail confirmation.\nManual send required. Consider: SELECT public.send_weekly_cpr_recap(''%s''::uuid, ''%s''::date) after resetting send_attempt_count.',
                 v_report.week_ending_date, v_report.send_attempt_count,
                 v_agency_id, v_report.week_ending_date));
        UPDATE public.weekly_cpr_reports SET escalation_alerted_at = now() WHERE id = v_report.id;
        v_escalated := v_escalated + 1;
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
  END IF;

  IF (v_reset_error + v_reset_stale) > 0 AND v_peter_chat IS NOT NULL THEN
    BEGIN PERFORM public.paper_newt_send_message(v_peter_chat,
      format(E'🟡 CPR verify: %s errors / %s stale reset\n\n%s',
             v_reset_error, v_reset_stale, left(v_details::text, 1000)));
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  IF v_recipe_id IS NOT NULL AND (v_confirmed + v_dispatched_verify + v_reset_error + v_reset_stale + v_escalated) > 0 THEN
    INSERT INTO public.automation_run_log
      (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started,
       CASE WHEN (v_reset_error + v_reset_stale + v_escalated) > 0 THEN 'partial' ELSE 'success' END,
       v_confirmed + v_dispatched_verify + v_reset_error + v_reset_stale + v_escalated,
       jsonb_build_object('confirmed', v_confirmed, 'verify_dispatched', v_dispatched_verify,
         'still_pending', v_still_pending, 'reset_error', v_reset_error,
         'reset_stale', v_reset_stale, 'escalated', v_escalated, 'details', v_details)::text,
       EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  END IF;

  RETURN jsonb_build_object('confirmed', v_confirmed, 'verify_dispatched', v_dispatched_verify,
    'still_pending', v_still_pending, 'reset_error', v_reset_error,
    'reset_stale', v_reset_stale, 'escalated', v_escalated, 'details', v_details);
END;
$function$;
