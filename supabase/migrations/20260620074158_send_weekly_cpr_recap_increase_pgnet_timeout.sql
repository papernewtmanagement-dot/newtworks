-- Bump pg_net timeout from default 5000ms to 30000ms. Composio Gmail send routinely
-- takes ~4.5-5s, occasionally over the 5s default — caught a timeout on the first test send.
-- The 30s ceiling matches the function's existing wait loop (60 × 500ms).
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
  v_response                record;
  v_attempts                int := 0;
  v_max_attempts            int := 60;
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
    v_subject_dates := v_start_mon || ' ' || v_start_day || '–' || v_end_day;
  ELSE
    v_subject_dates := v_start_mon || ' ' || v_start_day || ' – ' || v_end_mon || ' ' || v_end_day;
  END IF;

  v_subject := '📊 CPR RECAP — WEEK OF ' || v_subject_dates;

  v_html := public.compose_weekly_cpr_html(p_agency_id, p_week_ending_date);

  -- 30 second timeout. Composio Gmail occasionally exceeds the 5s default; the
  -- function's existing 30s wait loop already accommodates this on the response side.
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
    timeout_milliseconds := 30000
  ) INTO v_request_id;

  LOOP
    SELECT id, status_code, content, error_msg, created
      INTO v_response
      FROM net._http_response
      WHERE id = v_request_id;

    EXIT WHEN v_response.status_code IS NOT NULL OR v_response.error_msg IS NOT NULL OR v_attempts >= v_max_attempts;

    PERFORM pg_sleep(0.5);
    v_attempts := v_attempts + 1;
  END LOOP;

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
      'error', 'Composio request timed out after ' || (v_max_attempts * 0.5)::text || 's. Email may still send. Check net._http_response id=' || v_request_id::text || ' before retrying.',
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
    'wait_attempts', v_attempts
  );
END;
$function$;
