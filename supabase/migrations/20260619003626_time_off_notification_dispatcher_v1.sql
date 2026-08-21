-- ============================================================================
-- Step C: Time off notification dispatcher
-- Self-contained pg_cron + pg_net direct to Composio v3 Gmail API
-- ============================================================================

-- 1. Notification tracking columns on time_off_requests
ALTER TABLE public.time_off_requests
  ADD COLUMN IF NOT EXISTS voters_notified_at      timestamptz,
  ADD COLUMN IF NOT EXISTS vote_close_processed_at timestamptz,
  ADD COLUMN IF NOT EXISTS decision_notified_at    timestamptz;

-- 2. Notification log (audit trail of every email dispatched)
CREATE TABLE IF NOT EXISTS public.time_off_notification_log (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         uuid NOT NULL,
  request_id        uuid NOT NULL REFERENCES public.time_off_requests(id) ON DELETE CASCADE,
  notification_type text NOT NULL CHECK (notification_type IN ('vote_request','vote_closed','decision_requester','decision_team')),
  recipient_email   text NOT NULL,
  subject           text NOT NULL,
  pg_net_request_id bigint,
  sent_at           timestamptz NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS time_off_notification_log_request_idx
  ON public.time_off_notification_log (request_id, notification_type);

-- 3. Single-email sender via pg_net + Composio v3
CREATE OR REPLACE FUNCTION public.time_off_send_email(
  p_agency_id uuid,
  p_to text,
  p_subject text,
  p_html_body text
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_api_key text;
  v_user_id text;
  v_connected_account_id text;
  v_request_id bigint;
BEGIN
  SELECT setting_value INTO v_api_key
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';

  SELECT setting_value INTO v_user_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';

  SELECT setting_value INTO v_connected_account_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_gmail_account_id';

  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Gmail config missing in settings (api_key=%, user_id=%, connected_account_id=%)',
      v_api_key IS NOT NULL, v_user_id IS NOT NULL, v_connected_account_id IS NOT NULL;
  END IF;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/GMAIL_SEND_EMAIL',
    headers := jsonb_build_object(
      'x-api-key', v_api_key,
      'Content-Type', 'application/json'
    ),
    body    := jsonb_build_object(
      'user_id', v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments', jsonb_build_object(
        'recipient_email', p_to,
        'subject', p_subject,
        'body', p_html_body,
        'is_html', true
      )
    )
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$func$;

REVOKE EXECUTE ON FUNCTION public.time_off_send_email(uuid, text, text, text) FROM PUBLIC, anon, authenticated;

-- 4. Main dispatcher — polls + sends + transitions
CREATE OR REPLACE FUNCTION public.time_off_notification_dispatch(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_vote_request_emails int := 0;
  v_vote_closed_processed int := 0;
  v_decision_emails int := 0;
  v_req RECORD;
  v_voter RECORD;
  v_pg_net_id bigint;
  v_bcc_url text := 'https://storybccdashboard.vercel.app';
  v_peter_email text;
  v_vote_status jsonb;
  v_html text;
  v_subject text;
  v_when_text text;
  v_first_name text;
BEGIN
  -- Resolve Peter's email
  SELECT COALESCE(email_personal, email_sf) INTO v_peter_email
  FROM public.team
  WHERE agency_id = p_agency_id AND role_level = 'Owner' AND archived_at IS NULL
  ORDER BY hire_date LIMIT 1;

  -- ====================
  -- A. Vote-request emails to each voter (status=voting AND voters_notified_at IS NULL)
  -- ====================
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.notes,
           r.requester_team_id,
           (req_t.first_name || ' ' || req_t.last_name) AS requester_name,
           r.vote_closes_at
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status = 'voting'
      AND r.voters_notified_at IS NULL
  LOOP
    v_when_text := to_char(v_req.start_date, 'Dy, Mon DD');
    IF v_req.start_date <> v_req.end_date THEN
      v_when_text := v_when_text || ' through ' || to_char(v_req.end_date, 'Dy, Mon DD');
    END IF;
    v_subject := 'Vote needed: ' || v_req.requester_name || E'\'s time off request';

    FOR v_voter IN
      SELECT id, first_name, last_name,
             COALESCE(email_personal, email_sf) AS email
      FROM public.team
      WHERE agency_id = p_agency_id
        AND category = 'agency'
        AND archived_at IS NULL
        AND is_test_user IS NOT TRUE
        AND id <> v_req.requester_team_id
        AND COALESCE(email_personal, email_sf) IS NOT NULL
    LOOP
      v_html :=
        '<p>Hi ' || v_voter.first_name || ',</p>' ||
        '<p><strong>' || v_req.requester_name || '</strong> has requested time off:</p>' ||
        '<ul>' ||
        '<li><strong>Type:</strong> ' || replace(v_req.request_type, '_', ' ') || '</li>' ||
        '<li><strong>When:</strong> ' || v_when_text || '</li>' ||
        CASE WHEN v_req.notes IS NOT NULL
             THEN '<li><strong>Notes:</strong> ' || v_req.notes || '</li>'
             ELSE '' END ||
        '</ul>' ||
        '<p>Voting closes <strong>' || to_char(v_req.vote_closes_at AT TIME ZONE 'America/Chicago', 'Dy Mon DD at HH12:MI AM') || ' CT</strong>. Vote here:</p>' ||
        '<p><a href="' || v_bcc_url || '" style="display:inline-block;padding:10px 20px;background:#2563eb;color:#fff;text-decoration:none;border-radius:6px;font-weight:600;">Open BCC &rarr; Time Off</a></p>' ||
        '<p style="color:#64748b;font-size:13px;">If you don''t vote, it''s ok — Peter makes the final call regardless.</p>';

      v_pg_net_id := public.time_off_send_email(p_agency_id, v_voter.email, v_subject, v_html);

      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'vote_request', v_voter.email, v_subject, v_pg_net_id);

      v_vote_request_emails := v_vote_request_emails + 1;
    END LOOP;

    UPDATE public.time_off_requests
    SET voters_notified_at = NOW()
    WHERE id = v_req.id;
  END LOOP;

  -- ====================
  -- B. Vote closed -> transition + notify Peter
  -- ====================
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.notes,
           r.requester_team_id,
           (req_t.first_name || ' ' || req_t.last_name) AS requester_name
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status = 'voting'
      AND r.vote_closes_at < NOW()
      AND r.vote_close_processed_at IS NULL
  LOOP
    v_vote_status := public.time_off_vote_status(v_req.id);

    UPDATE public.time_off_requests
    SET status = 'awaiting_decision', vote_close_processed_at = NOW()
    WHERE id = v_req.id;

    IF v_peter_email IS NOT NULL THEN
      v_when_text := to_char(v_req.start_date, 'Dy, Mon DD');
      IF v_req.start_date <> v_req.end_date THEN
        v_when_text := v_when_text || ' through ' || to_char(v_req.end_date, 'Dy, Mon DD');
      END IF;

      v_subject := 'Time off vote closed: ' || v_req.requester_name || E'\'s request awaits your decision';

      v_html :=
        '<p>Voting just closed on <strong>' || v_req.requester_name || '</strong>''s time off request:</p>' ||
        '<ul>' ||
        '<li><strong>Type:</strong> ' || replace(v_req.request_type, '_', ' ') || '</li>' ||
        '<li><strong>When:</strong> ' || v_when_text || '</li>' ||
        '<li><strong>Vote tally:</strong> &#128077; ' || COALESCE(v_vote_status->>'yes_count','0') ||
          ' &middot; &#128078; ' || COALESCE(v_vote_status->>'no_count','0') ||
          ' &middot; &mdash; ' || COALESCE(v_vote_status->>'abstain_count','0') ||
          ' &middot; &#9208; ' || COALESCE(v_vote_status->>'non_responder_count','0') || ' (no response)</li>' ||
        '<li><strong>Quorum:</strong> ' || CASE WHEN (v_vote_status->>'quorum_met')::boolean THEN 'met' ELSE 'NOT met' END || '</li>' ||
        '<li><strong>Recommendation:</strong> ' || REPLACE(COALESCE(v_vote_status->>'recommendation', '—'), '_', ' ') || '</li>' ||
        '</ul>' ||
        '<p><a href="' || v_bcc_url || '" style="display:inline-block;padding:10px 20px;background:#2563eb;color:#fff;text-decoration:none;border-radius:6px;font-weight:600;">Open BCC Inbox &rarr; decide</a></p>';

      v_pg_net_id := public.time_off_send_email(p_agency_id, v_peter_email, v_subject, v_html);

      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'vote_closed', v_peter_email, v_subject, v_pg_net_id);
    END IF;

    v_vote_closed_processed := v_vote_closed_processed + 1;
  END LOOP;

  -- ====================
  -- C. Decision emails (approved/denied -> requester + team)
  -- ====================
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.status, r.decision_note,
           r.requester_team_id,
           (req_t.first_name || ' ' || req_t.last_name) AS requester_name,
           req_t.first_name AS requester_first_name,
           COALESCE(req_t.email_personal, req_t.email_sf) AS requester_email
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status IN ('approved', 'denied')
      AND r.decision_notified_at IS NULL
  LOOP
    v_when_text := to_char(v_req.start_date, 'Dy, Mon DD');
    IF v_req.start_date <> v_req.end_date THEN
      v_when_text := v_when_text || ' through ' || to_char(v_req.end_date, 'Dy, Mon DD');
    END IF;

    -- C.1: Email requester
    IF v_req.requester_email IS NOT NULL THEN
      v_subject := 'Time off ' || v_req.status || ': your request';
      v_html :=
        '<p>Hi ' || v_req.requester_first_name || ',</p>' ||
        '<p>Your time off request has been <strong>' || UPPER(v_req.status) || '</strong>:</p>' ||
        '<ul>' ||
        '<li><strong>Type:</strong> ' || replace(v_req.request_type, '_', ' ') || '</li>' ||
        '<li><strong>When:</strong> ' || v_when_text || '</li>' ||
        CASE WHEN v_req.decision_note IS NOT NULL
             THEN '<li><strong>Note from Peter:</strong> ' || v_req.decision_note || '</li>'
             ELSE '' END ||
        '</ul>' ||
        '<p>This is also in BCC &rarr; Time Off &rarr; My Requests.</p>';

      v_pg_net_id := public.time_off_send_email(p_agency_id, v_req.requester_email, v_subject, v_html);

      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'decision_requester', v_req.requester_email, v_subject, v_pg_net_id);
    END IF;

    -- C.2: Notify the rest of the team
    FOR v_voter IN
      SELECT first_name, COALESCE(email_personal, email_sf) AS email
      FROM public.team
      WHERE agency_id = p_agency_id
        AND category = 'agency'
        AND archived_at IS NULL
        AND is_test_user IS NOT TRUE
        AND id <> v_req.requester_team_id
        AND COALESCE(email_personal, email_sf) IS NOT NULL
    LOOP
      v_subject := 'Time off ' || v_req.status || ': ' || v_req.requester_name || E'\'s request';
      v_html :=
        '<p>Hi ' || v_voter.first_name || ',</p>' ||
        '<p><strong>' || v_req.requester_name || '</strong>''s time off request was <strong>' || UPPER(v_req.status) || '</strong>: ' || v_when_text || '.</p>';

      v_pg_net_id := public.time_off_send_email(p_agency_id, v_voter.email, v_subject, v_html);

      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'decision_team', v_voter.email, v_subject, v_pg_net_id);

      v_decision_emails := v_decision_emails + 1;
    END LOOP;

    UPDATE public.time_off_requests
    SET decision_notified_at = NOW()
    WHERE id = v_req.id;
  END LOOP;

  RETURN jsonb_build_object(
    'vote_request_emails', v_vote_request_emails,
    'vote_closed_processed', v_vote_closed_processed,
    'decision_emails', v_decision_emails,
    'dispatched_at', NOW()
  );
END;
$func$;

REVOKE EXECUTE ON FUNCTION public.time_off_notification_dispatch(uuid) FROM PUBLIC, anon, authenticated;

-- 5. Schedule via pg_cron — every 5 minutes
SELECT cron.schedule(
  'time_off_notification_dispatch',
  '*/5 * * * *',
  $sql$SELECT public.time_off_notification_dispatch();$sql$
);

-- 6. Register the recipe row for visibility in the Automations module
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description,
  trigger_type, cron_expression,
  internal_handler, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Time Off Notification Dispatch',
  'Polls time_off_requests every 5 min. Sends vote-request emails to voters when a request enters voting status. Transitions expired votes (vote_closes_at past) to awaiting_decision and notifies Peter. Sends decision emails to requester + team when status becomes approved/denied. Uses pg_cron + pg_net direct to Composio v3 Gmail API — bypasses automation-runner edge function.',
  'cron',
  '*/5 * * * *',
  'time_off_notification_dispatch',
  true
);
