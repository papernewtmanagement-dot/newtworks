-- Continue swap: work_checkin → time_off_participant in two remaining time-off functions.
-- Preserves current voter set; unlocks the work_checkin unlicensed/off-that-day filter
-- without collateral impact on time-off voting.

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
  v_app_url text := 'https://newtworks.vercel.app';
  v_peter_email text;
  v_vote_status jsonb;
  v_html text;
  v_subject text;
  v_when_text text;
  v_token text;
  v_type_display text;
BEGIN
  SELECT COALESCE(email_sf, email_personal) INTO v_peter_email
  FROM public.team
  WHERE agency_id = p_agency_id AND role_level = 'Owner' AND is_admin_backoffice = false AND archived_at IS NULL
  ORDER BY hire_date LIMIT 1;

  -- Vote-request emails
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.notes,
           r.requester_team_id, r.is_paid,
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
    v_type_display := public.time_off_display_label(v_req.request_type, v_req.is_paid);

    FOR v_voter IN
      SELECT team_id AS id, first_name, last_name,
             COALESCE(email_sf, email_personal) AS email
      FROM public.get_expected_teammates(p_agency_id, 'time_off_participant')
      WHERE team_id <> v_req.requester_team_id
        AND COALESCE(email_sf, email_personal) IS NOT NULL
    LOOP
      v_html :=
        '<p>Hi ' || v_voter.first_name || ',</p>' ||
        '<p><strong>' || v_req.requester_name || '</strong> has requested time off:</p>' ||
        '<ul>' ||
        '<li><strong>Type:</strong> ' || v_type_display || '</li>' ||
        '<li><strong>When:</strong> ' || v_when_text || '</li>' ||
        CASE WHEN v_req.notes IS NOT NULL THEN '<li><strong>Notes:</strong> ' || v_req.notes || '</li>' ELSE '' END ||
        '</ul>' ||
        '<p>Voting closes <strong>' || to_char(v_req.vote_closes_at AT TIME ZONE 'America/Chicago', 'Dy Mon DD at HH12:MI AM') || ' CT</strong>.</p>' ||
        '<p><strong>Two ways to vote:</strong></p>' ||
        '<ol>' ||
        '<li><a href="' || v_app_url || '" style="color:#2563eb;font-weight:600;">Open Newtworks &rarr; Time Off</a></li>' ||
        '<li>Reply to this email with <strong>Yes</strong>, <strong>No</strong>, or <strong>Abstain</strong>. A sentence is welcome &mdash; it gets logged as your reason.</li>' ||
        '</ol>' ||
        '<p style="color:#64748b;font-size:13px;">If you don''t vote, it''s ok &mdash; Peter makes the final call regardless. ' ||
        'Keep the <code>[#' || v_token || ']</code> in the subject when you reply so the vote gets matched to the right request.</p>';

      v_pg_net_id := public.time_off_send_email(p_agency_id, v_voter.email, v_subject, v_html);
      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'vote_request', v_voter.email, v_subject, v_pg_net_id);
      v_vote_request_emails := v_vote_request_emails + 1;
    END LOOP;

    UPDATE public.time_off_requests SET voters_notified_at = NOW() WHERE id = v_req.id;
  END LOOP;

  -- Vote-closed → notify Peter
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.notes,
           r.requester_team_id, r.is_paid,
           (req_t.first_name || ' ' || req_t.last_name) AS requester_name
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status = 'voting'
      AND r.vote_closes_at < NOW()
      AND r.vote_close_processed_at IS NULL
  LOOP
    v_vote_status := public.time_off_vote_status(v_req.id);
    UPDATE public.time_off_requests SET status = 'awaiting_decision', vote_close_processed_at = NOW() WHERE id = v_req.id;
    v_type_display := public.time_off_display_label(v_req.request_type, v_req.is_paid);

    IF v_peter_email IS NOT NULL THEN
      v_when_text := to_char(v_req.start_date, 'Dy, Mon DD');
      IF v_req.start_date <> v_req.end_date THEN
        v_when_text := v_when_text || ' through ' || to_char(v_req.end_date, 'Dy, Mon DD');
      END IF;
      v_subject := 'Time off vote closed: ' || v_req.requester_name || E'\'s request awaits your decision';
      v_html :=
        '<p>Voting just closed on <strong>' || v_req.requester_name || '</strong>''s time off request:</p>' ||
        '<ul>' ||
        '<li><strong>Type:</strong> ' || v_type_display || '</li>' ||
        '<li><strong>When:</strong> ' || v_when_text || '</li>' ||
        '<li><strong>Vote tally:</strong> &#128077; ' || COALESCE(v_vote_status->>'yes_count','0') ||
          ' &middot; &#128078; ' || COALESCE(v_vote_status->>'no_count','0') ||
          ' &middot; &mdash; ' || COALESCE(v_vote_status->>'abstain_count','0') ||
          ' &middot; &#9208; ' || COALESCE(v_vote_status->>'non_responder_count','0') || ' (no response)</li>' ||
        '<li><strong>Quorum:</strong> ' || CASE WHEN (v_vote_status->>'quorum_met')::boolean THEN 'met' ELSE 'NOT met' END || '</li>' ||
        '<li><strong>Recommendation:</strong> ' || REPLACE(COALESCE(v_vote_status->>'recommendation', '—'), '_', ' ') || '</li>' ||
        '</ul>' ||
        '<p><a href="' || v_app_url || '" style="display:inline-block;padding:10px 20px;background:#2563eb;color:#fff;text-decoration:none;border-radius:6px;font-weight:600;">Open Newtworks Inbox &rarr; decide</a></p>';

      v_pg_net_id := public.time_off_send_email(p_agency_id, v_peter_email, v_subject, v_html);
      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'vote_closed', v_peter_email, v_subject, v_pg_net_id);
    END IF;
    v_vote_closed_processed := v_vote_closed_processed + 1;
  END LOOP;

  -- Decision emails
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.status, r.decision_note,
           r.requester_team_id, r.is_paid,
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
    v_type_display := public.time_off_display_label(v_req.request_type, v_req.is_paid);

    IF v_req.requester_email IS NOT NULL THEN
      v_subject := 'Time off ' || v_req.status || ': your request';
      v_html :=
        '<p>Hi ' || v_req.requester_first_name || ',</p>' ||
        '<p>Your time off request has been <strong>' || UPPER(v_req.status) || '</strong>:</p>' ||
        '<ul>' ||
        '<li><strong>Type:</strong> ' || v_type_display || '</li>' ||
        '<li><strong>When:</strong> ' || v_when_text || '</li>' ||
        CASE WHEN v_req.decision_note IS NOT NULL THEN '<li><strong>Note from Peter:</strong> ' || v_req.decision_note || '</li>' ELSE '' END ||
        '</ul>' ||
        '<p>This is also in Newtworks &rarr; Time Off &rarr; My Requests.</p>';
      v_pg_net_id := public.time_off_send_email(p_agency_id, v_req.requester_email, v_subject, v_html);
      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'decision_requester', v_req.requester_email, v_subject, v_pg_net_id);
    END IF;

    FOR v_voter IN
      SELECT first_name, COALESCE(email_sf, email_personal) AS email
      FROM public.get_expected_teammates(p_agency_id, 'time_off_participant')
      WHERE team_id <> v_req.requester_team_id
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

    UPDATE public.time_off_requests SET decision_notified_at = NOW() WHERE id = v_req.id;
  END LOOP;

  RETURN jsonb_build_object(
    'vote_request_emails', v_vote_request_emails,
    'vote_closed_processed', v_vote_closed_processed,
    'decision_emails', v_decision_emails,
    'dispatched_at', NOW()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.time_off_vote_status(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_request RECORD;
  v_eligible_voter_count integer;
  v_yes_count integer;
  v_no_count integer;
  v_abstain_count integer;
  v_votes_cast integer;
  v_quorum_threshold integer;
  v_quorum_met boolean;
  v_simple_majority_yes boolean;
  v_recommendation text;
BEGIN
  SELECT * INTO v_request FROM public.time_off_requests WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'request not found');
  END IF;

  -- Eligible voters = time_off_participant roster minus the requester
  SELECT COUNT(*)::int INTO v_eligible_voter_count
  FROM public.get_expected_teammates(v_request.agency_id, 'time_off_participant')
  WHERE team_id IS DISTINCT FROM v_request.requester_team_id;

  SELECT
    COUNT(*) FILTER (WHERE vote = 'yes'),
    COUNT(*) FILTER (WHERE vote = 'no'),
    COUNT(*) FILTER (WHERE vote = 'abstain'),
    COUNT(*)
  INTO v_yes_count, v_no_count, v_abstain_count, v_votes_cast
  FROM public.time_off_votes
  WHERE request_id = p_request_id;

  v_quorum_threshold := CEIL(v_eligible_voter_count / 2.0)::integer;
  v_quorum_met := v_votes_cast >= v_quorum_threshold;
  v_simple_majority_yes := (v_yes_count + v_no_count) > 0 AND v_yes_count > v_no_count;

  IF NOT v_quorum_met THEN
    v_recommendation := 'no_quorum_escalate_to_owner';
  ELSIF v_simple_majority_yes THEN
    v_recommendation := 'team_leans_yes';
  ELSIF v_yes_count = v_no_count THEN
    v_recommendation := 'tied_escalate_to_owner';
  ELSE
    v_recommendation := 'team_leans_no';
  END IF;

  RETURN jsonb_build_object(
    'eligible_voter_count', v_eligible_voter_count,
    'votes_cast', v_votes_cast,
    'yes_count', v_yes_count,
    'no_count', v_no_count,
    'abstain_count', v_abstain_count,
    'non_responder_count', v_eligible_voter_count - v_votes_cast,
    'quorum_threshold', v_quorum_threshold,
    'quorum_met', v_quorum_met,
    'simple_majority_yes', v_simple_majority_yes,
    'recommendation', v_recommendation
  );
END;
$function$;
