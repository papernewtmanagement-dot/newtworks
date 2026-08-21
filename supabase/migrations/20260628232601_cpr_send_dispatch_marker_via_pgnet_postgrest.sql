-- =====================================================================
-- CPR SEND: dispatch idempotency via pg_net → PostgREST autonomous mark
-- ---------------------------------------------------------------------
-- Problem: pg_net.http_post() commits its request to net.http_request_queue
-- eagerly (independent of caller transaction). If the calling function is
-- later killed mid-poll, the rollback undoes UPDATE sent_to_team_at but
-- does NOT undo the already-dispatched HTTP request. Result: email ships
-- but no record of it. A subsequent retry sees sent_to_team_at IS NULL
-- and dispatches AGAIN → double-send (occurred 2026-06-28).
--
-- Fix: a second column `send_dispatched_at`, set BEFORE the Composio POST
-- via a pg_net call to PostgREST RPC. That pg_net call ALSO commits
-- eagerly, so it lands in pg_net's queue independent of caller tx. The
-- PostgREST worker executes the mark in its own transaction. Survives
-- caller rollback. Retry sees send_dispatched_at set and refuses.
--
-- Tiny residual race: ~sub-second window between pg_net dispatching the
-- mark and PostgREST executing it. Manual/cron retries don't happen in
-- that window in practice.
-- =====================================================================

-- 1. Schema: dispatch marker + request_id for traceability
ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS send_dispatched_at timestamptz,
  ADD COLUMN IF NOT EXISTS send_request_id    bigint;

COMMENT ON COLUMN public.weekly_cpr_reports.send_dispatched_at IS
  'Set autonomously via pg_net→PostgREST RPC just before the Composio Gmail POST. Survives caller transaction rollback. Dispatch idempotency guard — if set, send_weekly_cpr_recap refuses to re-dispatch.';
COMMENT ON COLUMN public.weekly_cpr_reports.send_request_id IS
  'pg_net request_id for the Composio Gmail POST. Set within caller tx (rolls back if function killed). Used for post-mortem reconciliation: if send_dispatched_at IS NOT NULL AND sent_to_team_at IS NULL, look up the response in net._http_response.';

-- 2. Autonomous mark function (called via PostgREST RPC from pg_net)
CREATE OR REPLACE FUNCTION public.mark_cpr_dispatched(p_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.weekly_cpr_reports
     SET send_dispatched_at = NOW()
   WHERE id = p_id
     AND send_dispatched_at IS NULL;
$$;

REVOKE ALL ON FUNCTION public.mark_cpr_dispatched(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_cpr_dispatched(uuid) TO service_role;

-- 3. Backfill: existing sent reports should have send_dispatched_at set
--    so the new guard is consistent for historical rows.
UPDATE public.weekly_cpr_reports
   SET send_dispatched_at = sent_to_team_at
 WHERE sent_to_team_at IS NOT NULL
   AND send_dispatched_at IS NULL;

-- 4. Modified send_weekly_cpr_recap with autonomous dispatch mark
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
  v_max_attempts            int := 300;       -- 300 × 0.5s = 150s polling ceiling
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

  -- NEW: dispatch idempotency guard. send_dispatched_at is set autonomously
  -- (via pg_net→PostgREST) BEFORE the Composio POST below, so it survives
  -- caller rollback. If set, a prior invocation already dispatched the
  -- Composio request — even if we never recorded sent_to_team_at, the email
  -- likely shipped. Refuse to retry. Manual recovery: NULL out
  -- send_dispatched_at after verifying no email reached the team.
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
    v_subject_dates := v_start_mon || ' ' || v_start_day || '-' || v_end_day;
  ELSE
    v_subject_dates := v_start_mon || ' ' || v_start_day || ' - ' || v_end_mon || ' ' || v_end_day;
  END IF;

  v_subject := E'\xF0\x9F\x93\x8A CPR RECAP \xE2\x80\x94 WEEK OF ' || v_subject_dates;

  v_html := public.compose_weekly_cpr_html(p_agency_id, p_week_ending_date);

  -- NEW: AUTONOMOUS DISPATCH MARK via pg_net→PostgREST RPC.
  -- This commits send_dispatched_at = NOW() in its OWN transaction, INDEPENDENT
  -- of this function's transaction. Even if this function is killed mid-poll
  -- below and rolls back, the mark persists — so a retry will see it and
  -- refuse to re-dispatch. Fire-and-forget; we don't poll for the response.
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

  -- 180-second pg_net request timeout (bumped 2026-06-21 from 90s after a
  -- resend exposed Composio response landing at ~108s). Primary auto-sends
  -- typically land in 30-35s; window sized for slow-Composio days.
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

  -- Stash request_id for traceability. Rolls back with the function if killed,
  -- which is fine — the autonomous mark above is the safety net.
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

  -- LATE-LANDING RECOVERY SWEEP. If the loop exited without a response,
  -- give Composio one more chance (30s) to land before declaring timeout.
  -- A late 2xx is treated as success (the email actually shipped).
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
