-- Rewrite send_weekly_cpr_recap to fire-and-forget (no polling loop).
-- Root cause of 2026-07-05 Sunday auto-send failure: 150s polling loop + 30s recovery
-- inside send_weekly_cpr_recap exceeds pg_cron's 120s per-job session cap
-- whenever Composio takes non-trivial time to respond. Whole transaction rolls back
-- → no email, no run_log, no dispatch flag.
-- New shape: dispatch, capture request_id, return in ~0.1s. finalize_pending_cpr_sends()
-- runs every minute and stamps sent_to_team_at from net._http_response, resetting on
-- error or after 10 min of no response.

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
  SELECT * INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'No weekly_cpr_reports row exists for this week.');
  END IF;

  IF v_report.sent_to_team_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Already sent at ' || v_report.sent_to_team_at::text);
  END IF;

  IF v_report.send_dispatched_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Send already dispatched at ' || v_report.send_dispatched_at::text ||
               '. finalize_pending_cpr_sends will resolve. ' ||
               'Check net._http_response for send_request_id=' || COALESCE(v_report.send_request_id::text, 'NULL') ||
               '. To force retry, manually NULL send_dispatched_at.',
      'send_request_id', v_report.send_request_id
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

  -- Mark dispatched BEFORE firing (guard against re-fire from concurrent callers)
  UPDATE public.weekly_cpr_reports
     SET send_dispatched_at = now()
   WHERE id = v_report.id;

  -- Fire async, capture request_id, return. finalize_pending_cpr_sends()
  -- will stamp sent_to_team_at once Composio responds.
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

  UPDATE public.weekly_cpr_reports
     SET send_request_id = v_request_id
   WHERE id = v_report.id;

  RETURN jsonb_build_object(
    'success', true,
    'status', 'pending',
    'request_id', v_request_id,
    'subject', v_subject,
    'recipients', v_recipients_to,
    'recipient_count', array_length(v_recipients_to, 1),
    'note', 'Dispatched to Composio. finalize_pending_cpr_sends will stamp sent_to_team_at once response arrives.'
  );
END;
$function$;

-- Finalize any dispatched-but-not-yet-confirmed sends.
-- Runs on 1-min cron. Exits fast when nothing pending.
CREATE OR REPLACE FUNCTION public.finalize_pending_cpr_sends()
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
  v_response        record;
  v_finalized       int := 0;
  v_still_pending   int := 0;
  v_failed          int := 0;
  v_stale           int := 0;
  v_details         jsonb := '[]'::jsonb;
  v_peter_chat      bigint;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'finalize_pending_cpr_sends' LIMIT 1;

  FOR v_report IN
    SELECT id, week_ending_date, send_request_id, send_dispatched_at
      FROM public.weekly_cpr_reports
     WHERE agency_id = v_agency_id
       AND sent_to_team_at IS NULL
       AND send_dispatched_at IS NOT NULL
       AND send_request_id IS NOT NULL
     ORDER BY send_dispatched_at
  LOOP
    SELECT id, status_code, content, error_msg, created
      INTO v_response
      FROM net._http_response
     WHERE id = v_report.send_request_id;

    IF v_response.id IS NULL THEN
      IF v_report.send_dispatched_at < now() - INTERVAL '10 minutes' THEN
        UPDATE public.weekly_cpr_reports
           SET send_dispatched_at = NULL, send_request_id = NULL
         WHERE id = v_report.id;
        v_stale := v_stale + 1;
        v_details := v_details || jsonb_build_object(
          'week_ending_date', v_report.week_ending_date,
          'action', 'reset_stale',
          'dispatched_at', v_report.send_dispatched_at,
          'request_id', v_report.send_request_id
        );
      ELSE
        v_still_pending := v_still_pending + 1;
      END IF;

    ELSIF v_response.status_code BETWEEN 200 AND 299 THEN
      UPDATE public.weekly_cpr_reports
         SET sent_to_team_at = COALESCE(v_response.created, now())
       WHERE id = v_report.id;
      v_finalized := v_finalized + 1;
      v_details := v_details || jsonb_build_object(
        'week_ending_date', v_report.week_ending_date,
        'action', 'stamped_sent',
        'status_code', v_response.status_code,
        'sent_to_team_at', COALESCE(v_response.created, now())
      );

    ELSE
      UPDATE public.weekly_cpr_reports
         SET send_dispatched_at = NULL, send_request_id = NULL
       WHERE id = v_report.id;
      v_failed := v_failed + 1;
      v_details := v_details || jsonb_build_object(
        'week_ending_date', v_report.week_ending_date,
        'action', 'reset_error',
        'status_code', v_response.status_code,
        'error_msg', v_response.error_msg,
        'body', left(coalesce(v_response.content, ''), 500)
      );
    END IF;
  END LOOP;

  IF v_failed > 0 OR v_stale > 0 THEN
    BEGIN
      SELECT ttm.telegram_user_id INTO v_peter_chat
        FROM public.team_telegram_map ttm
        JOIN public.team t ON t.id = ttm.team_id
       WHERE t.agency_id = v_agency_id
         AND t.role_level = 'Owner'
         AND t.is_admin_backoffice = false
         AND coalesce(ttm.is_excluded, false) = false
       LIMIT 1;

      IF v_peter_chat IS NOT NULL THEN
        PERFORM public.paper_newt_send_message(v_peter_chat,
          format(E'🔴 CPR finalize: %s failed / %s stale\n\n%s',
                 v_failed, v_stale, v_details::text));
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;

  IF v_recipe_id IS NOT NULL AND (v_finalized + v_failed + v_stale + v_still_pending) > 0 THEN
    INSERT INTO public.automation_run_log
      (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
    VALUES
      (v_agency_id, v_recipe_id, v_run_started,
       CASE WHEN v_failed > 0 OR v_stale > 0 THEN 'partial' ELSE 'success' END,
       v_finalized + v_failed + v_stale,
       jsonb_build_object(
         'finalized', v_finalized,
         'still_pending', v_still_pending,
         'failed', v_failed,
         'stale', v_stale,
         'details', v_details
       )::text,
       EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  END IF;

  RETURN jsonb_build_object(
    'finalized', v_finalized,
    'still_pending', v_still_pending,
    'failed', v_failed,
    'stale', v_stale,
    'details', v_details
  );
END;
$function$;

-- Register recipe row (for automation_run_log FK). Actual schedule owned by pg_cron.
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, trigger_type, cron_expression, is_active, recipe_description, internal_handler)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'finalize_pending_cpr_sends',
  'manual',
  NULL,
  true,
  'Every-minute finalizer for fire-and-forget CPR sends. Stamps sent_to_team_at once Composio responds; resets dispatch flag on 4xx/5xx or after 10 min of no response. Scheduling owned by pg_cron job "finalize_pending_cpr_sends".',
  'finalize_pending_cpr_sends'
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'finalize_pending_cpr_sends'
);

-- pg_cron job (idempotent)
DO $outer$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'finalize_pending_cpr_sends') THEN
    PERFORM cron.schedule(
      'finalize_pending_cpr_sends',
      '* * * * *',
      $cron$ SELECT public.finalize_pending_cpr_sends(); $cron$
    );
  END IF;
END $outer$;

-- Fix stale description on weekly_cpr_auto_send (referenced Sat/Sun 23:59 CT; actual pg_cron is Sat/Sun/Mon 6 AM CT)
UPDATE public.automation_recipes
   SET recipe_description = 'Auto-sends the Weekly CPR Recap to the team. pg_cron fires Sat/Sun/Mon at 6 AM CT (11:00 + 12:00 UTC dual-fire for DST; function skips wrong-DST hour). try_send_weekly_cpr_recap() computes the most recent Saturday in CT, checks readiness (opener≥100 chars + looking_ahead≥50 chars, not already sent), calls send_weekly_cpr_recap() which fires the Composio Gmail POST async and returns immediately (fire-and-forget). finalize_pending_cpr_sends stamps sent_to_team_at once Composio responds. If opener/looking_ahead not ready or send fails, Telegram alerts Peter with day-appropriate retry note (Sat: Sun+Mon backups; Sun: Mon backup; Mon: no auto-retry, manual send). [2026-06-21] cron_expression removed — scheduling owned by pg_cron jobid 6. [2026-07-05] Refactored to fire-and-forget to escape pg_cron 120s session cap.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND recipe_name = 'weekly_cpr_auto_send';
