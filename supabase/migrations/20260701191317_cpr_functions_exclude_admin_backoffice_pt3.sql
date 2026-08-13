-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-01 19:13:17 UTC (ledger name: cpr_functions_exclude_admin_backoffice_pt3) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260701191317.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- 5) send_weekly_cpr_recap — recipient list must exclude Marie so she doesn't
-- receive the team CPR email even if Peter fills in her email_sf later.
CREATE OR REPLACE FUNCTION public.send_weekly_cpr_recap(p_agency_id uuid, p_week_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
 SET statement_timeout TO '210000'
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
  v_response                record;
  v_attempts                int := 0;
  v_max_attempts            int := 300;
  v_late_recovered          boolean := false;
  v_supabase_url            text;
  v_service_role_key        text;
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
               '. Composio likely shipped the email even if sent_to_team_at is NULL. ' ||
               'Check net._http_response for send_request_id=' || COALESCE(v_report.send_request_id::text, 'NULL') ||
               '. To force retry, manually NULL send_dispatched_at after verifying.',
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
  SELECT setting_value INTO v_supabase_url
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'supabase_url';
  SELECT setting_value INTO v_service_role_key
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'supabase_service_role_key';

  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Composio Gmail config missing in settings');
  END IF;

  IF v_supabase_url IS NULL OR v_service_role_key IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'supabase_url or supabase_service_role_key missing from settings — required for autonomous dispatch mark');
  END IF;

  -- 2026-07-01: exclude is_admin_backoffice from CPR recipient list
  SELECT array_agg(email_sf ORDER BY
                   CASE WHEN role_level = 'Owner' THEN 1 ELSE 0 END,
                   hire_date ASC NULLS LAST, last_name)
    INTO v_recipients_to
  FROM public.team
  WHERE agency_id   = p_agency_id
    AND category    = 'agency'
    AND is_active   = true
    AND is_admin_backoffice = false  -- 2026-07-01
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

  PERFORM net.http_post(
    url     := v_supabase_url || '/rest/v1/rpc/mark_cpr_dispatched',
    headers := jsonb_build_object(
      'apikey',        v_service_role_key,
      'Authorization', 'Bearer ' || v_service_role_key,
      'Content-Type',  'application/json'
    ),
    body    := jsonb_build_object('p_id', v_report.id),
    timeout_milliseconds := 5000
  );

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

  LOOP
    SELECT id, status_code, content, error_msg, created
      INTO v_response
      FROM net._http_response
      WHERE id = v_request_id;

    EXIT WHEN v_response.status_code IS NOT NULL OR v_response.error_msg IS NOT NULL OR v_attempts >= v_max_attempts;

    PERFORM pg_sleep(0.5);
    v_attempts := v_attempts + 1;
  END LOOP;

  IF v_response.status_code IS NULL AND v_response.error_msg IS NULL THEN
    PERFORM pg_sleep(30);
    SELECT id, status_code, content, error_msg, created
      INTO v_response
      FROM net._http_response
      WHERE id = v_request_id;
    IF v_response.status_code BETWEEN 200 AND 299 THEN
      v_late_recovered := true;
    END IF;
  END IF;

  IF v_response.error_msg IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'pg_net error: ' || v_response.error_msg,
      'request_id', v_request_id
    );
  END IF;

  IF v_response.status_code IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Composio request timed out after ~180s (150s poll + 30s recovery). Email may still send. Check net._http_response id=' || v_request_id::text || ' before retrying.',
      'request_id', v_request_id
    );
  END IF;

  IF v_response.status_code NOT BETWEEN 200 AND 299 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Composio returned HTTP ' || v_response.status_code::text,
      'response_body', left(coalesce(v_response.content, ''), 1000),
      'request_id', v_request_id
    );
  END IF;

  UPDATE public.weekly_cpr_reports
     SET sent_to_team_at = now()
   WHERE id = v_report.id;

  RETURN jsonb_build_object(
    'success', true,
    'request_id', v_request_id,
    'status_code', v_response.status_code,
    'subject', v_subject,
    'recipients', v_recipients_to,
    'recipient_count', array_length(v_recipients_to, 1),
    'sent_to_team_at', now(),
    'wait_attempts', v_attempts,
    'late_recovered', v_late_recovered
  );
END;
$function$;
