-- =====================================================================
-- Time Off email-reply voting
-- Lets voters reply to vote-request email with Yes/No/Abstain instead
-- of clicking through to BCC. Subject-line [#xxxxxxxx] token resolves
-- the request; sender email resolves the voter.
-- =====================================================================

-- 1) Staging table for parsed reply emails -----------------------------
CREATE TABLE IF NOT EXISTS public.time_off_email_vote_replies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid
    REFERENCES public.agency(id),
  source_message_id text NOT NULL,
  received_at timestamptz NOT NULL,
  sender_email text NOT NULL,
  request_token text,
  raw_subject text,
  raw_snippet text,
  vote text,
  reason text,
  resolved_request_id uuid,
  resolved_voter_team_id uuid,
  processed_at timestamptz,
  processing_status text NOT NULL DEFAULT 'pending'
    CHECK (processing_status IN (
      'pending','recorded','no_token','no_request_match',
      'voter_not_recognized','voter_not_eligible',
      'vote_closed','no_vote_classified','error'
    )),
  processing_note text,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS time_off_email_vote_replies_msg_uidx
  ON public.time_off_email_vote_replies(source_message_id);

CREATE INDEX IF NOT EXISTS time_off_email_vote_replies_status_idx
  ON public.time_off_email_vote_replies(agency_id, processing_status, received_at DESC);

ALTER TABLE public.time_off_email_vote_replies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tovr_owner_read ON public.time_off_email_vote_replies;
CREATE POLICY tovr_owner_read ON public.time_off_email_vote_replies
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.role = 'owner'
    )
  );

-- 2) Trigger: resolve + record into time_off_votes ---------------------
CREATE OR REPLACE FUNCTION public.process_time_off_email_vote_reply()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_request RECORD;
  v_voter_id uuid;
  v_alert_ref text;
BEGIN
  -- 1. Subject token required
  IF NEW.request_token IS NULL OR LENGTH(NEW.request_token) <> 8 THEN
    NEW.processing_status := 'no_token';
    NEW.processing_note   := 'Reply subject did not contain [#xxxxxxxx] token';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  -- 2. Resolve request from token (first 8 chars of UUID)
  SELECT r.id, r.status, r.vote_closes_at, r.requester_team_id
  INTO v_request
  FROM public.time_off_requests r
  WHERE r.agency_id = NEW.agency_id
    AND SUBSTRING(r.id::text, 1, 8) = LOWER(NEW.request_token)
  LIMIT 1;

  IF NOT FOUND THEN
    NEW.processing_status := 'no_request_match';
    NEW.processing_note   := 'No request found for token ' || NEW.request_token;
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;
  NEW.resolved_request_id := v_request.id;

  -- 3. Resolve voter from sender email
  SELECT id INTO v_voter_id
  FROM public.team
  WHERE agency_id = NEW.agency_id
    AND archived_at IS NULL
    AND (LOWER(email_sf)       = LOWER(NEW.sender_email)
      OR LOWER(email_personal) = LOWER(NEW.sender_email))
  LIMIT 1;

  IF v_voter_id IS NULL THEN
    NEW.processing_status := 'voter_not_recognized';
    NEW.processing_note   := 'No active team member with email ' || NEW.sender_email;
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;
  NEW.resolved_voter_team_id := v_voter_id;

  -- 4. Voter cannot be requester
  IF v_voter_id = v_request.requester_team_id THEN
    NEW.processing_status := 'voter_not_eligible';
    NEW.processing_note   := 'Voter is the requester';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  -- 5. Voter must be on the include_in_team_checkins list
  IF NOT EXISTS (
    SELECT 1 FROM public.team
    WHERE id = v_voter_id
      AND include_in_team_checkins = true
      AND is_test_user IS NOT TRUE
  ) THEN
    NEW.processing_status := 'voter_not_eligible';
    NEW.processing_note   := 'Voter not on include_in_team_checkins list';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  -- 6. Vote-window enforcement: must be in voting OR awaiting_decision,
  --    and reply must have been received within vote_closes_at + 1h grace
  IF v_request.status NOT IN ('voting', 'awaiting_decision') THEN
    NEW.processing_status := 'vote_closed';
    NEW.processing_note   := 'Request status is ' || v_request.status || ' — vote not recorded';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  IF NEW.received_at > v_request.vote_closes_at + INTERVAL '1 hour' THEN
    NEW.processing_status := 'vote_closed';
    NEW.processing_note   := 'Reply received after vote_closes_at + 1h grace';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  -- 7. Vote classification required; unclassifiable → surface to Peter
  IF NEW.vote IS NULL OR NEW.vote NOT IN ('yes','no','abstain') THEN
    NEW.processing_status := 'no_vote_classified';
    NEW.processing_note   := 'Reply text could not be auto-classified';
    NEW.processed_at      := NOW();

    v_alert_ref := 'time_off_vote_reply_unclassified:' || NEW.source_message_id;
    IF NOT EXISTS (
      SELECT 1 FROM public.alerts
      WHERE agency_id = NEW.agency_id AND module_reference = v_alert_ref
    ) THEN
      INSERT INTO public.alerts (
        agency_id, module_reference, severity, title, message, is_resolved
      ) VALUES (
        NEW.agency_id,
        v_alert_ref,
        'info',
        'Email vote reply could not be auto-classified',
        'Reply from ' || NEW.sender_email || ' on request [#' || NEW.request_token ||
          '] could not be classified as yes/no/abstain. Reply: "' ||
          COALESCE(LEFT(NEW.raw_snippet, 240), '(no snippet)') ||
          '". Open BCC > Time Off to vote manually if appropriate.',
        false
      );
    END IF;
    RETURN NEW;
  END IF;

  -- 8. Upsert the vote
  INSERT INTO public.time_off_votes (request_id, voter_team_id, vote, reason, voted_at)
  VALUES (v_request.id, v_voter_id, NEW.vote, NEW.reason, NEW.received_at)
  ON CONFLICT (request_id, voter_team_id)
  DO UPDATE SET
    vote     = EXCLUDED.vote,
    reason   = EXCLUDED.reason,
    voted_at = EXCLUDED.voted_at;

  NEW.processing_status := 'recorded';
  NEW.processed_at      := NOW();
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_process_time_off_email_vote_reply
  ON public.time_off_email_vote_replies;
CREATE TRIGGER trg_process_time_off_email_vote_reply
  BEFORE INSERT ON public.time_off_email_vote_replies
  FOR EACH ROW EXECUTE FUNCTION public.process_time_off_email_vote_reply();

-- 3) Update vote-request email to include the [#token] + reply path ---
CREATE OR REPLACE FUNCTION public.time_off_notification_dispatch(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $function$
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
  v_token text;
BEGIN
  SELECT COALESCE(email_sf, email_personal) INTO v_peter_email
  FROM public.team
  WHERE agency_id = p_agency_id AND role_level = 'Owner' AND archived_at IS NULL
  ORDER BY hire_date LIMIT 1;

  -- A. Vote-request emails
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
    v_token := SUBSTRING(v_req.id::text, 1, 8);

    v_when_text := to_char(v_req.start_date, 'Dy, Mon DD');
    IF v_req.start_date <> v_req.end_date THEN
      v_when_text := v_when_text || ' through ' || to_char(v_req.end_date, 'Dy, Mon DD');
    END IF;
    v_subject := 'Vote needed: ' || v_req.requester_name || E'\'s time off request [#' || v_token || ']';

    FOR v_voter IN
      SELECT id, first_name, last_name,
             COALESCE(email_sf, email_personal) AS email
      FROM public.team
      WHERE agency_id = p_agency_id
        AND include_in_team_checkins = true
        AND archived_at IS NULL
        AND is_test_user IS NOT TRUE
        AND id <> v_req.requester_team_id
        AND COALESCE(email_sf, email_personal) IS NOT NULL
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
        '<p>Voting closes <strong>' || to_char(v_req.vote_closes_at AT TIME ZONE 'America/Chicago', 'Dy Mon DD at HH12:MI AM') || ' CT</strong>.</p>' ||
        '<p><strong>Two ways to vote:</strong></p>' ||
        '<ol>' ||
        '<li><a href="' || v_bcc_url || '" style="color:#2563eb;font-weight:600;">Open BCC &rarr; Time Off</a></li>' ||
        '<li>Reply to this email with <strong>Yes</strong>, <strong>No</strong>, or <strong>Abstain</strong>. A sentence is welcome &mdash; it gets logged as your reason.</li>' ||
        '</ol>' ||
        '<p style="color:#64748b;font-size:13px;">If you don''t vote, it''s ok &mdash; Peter makes the final call regardless. ' ||
        'Keep the <code>[#' || v_token || ']</code> in the subject when you reply so the vote gets matched to the right request.</p>';

      v_pg_net_id := public.time_off_send_email(p_agency_id, v_voter.email, v_subject, v_html);

      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'vote_request', v_voter.email, v_subject, v_pg_net_id);

      v_vote_request_emails := v_vote_request_emails + 1;
    END LOOP;

    UPDATE public.time_off_requests
    SET voters_notified_at = NOW()
    WHERE id = v_req.id;
  END LOOP;

  -- B. Vote closed -> transition + notify Peter
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

  -- C. Decision emails
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.status, r.decision_note,
           r.requester_team_id,
           (req_t.first_name || ' ' || req_t.last_name) AS requester_name,
           req_t.first_name AS requester_first_name,
           COALESCE(req_t.email_sf, req_t.email_personal) AS requester_email
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

    FOR v_voter IN
      SELECT first_name, COALESCE(email_sf, email_personal) AS email
      FROM public.team
      WHERE agency_id = p_agency_id
        AND include_in_team_checkins = true
        AND archived_at IS NULL
        AND is_test_user IS NOT TRUE
        AND id <> v_req.requester_team_id
        AND COALESCE(email_sf, email_personal) IS NOT NULL
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
$function$;
