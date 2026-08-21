-- Phase 2 helpers: notice check, eligibility check, coverage check, vote status
-- Spec source: persistent_memory id fcaa841a-68f0-481c-a348-9d07f1699a85

-- ============================================================================
-- 1. Backfill team_checkins flag for active non-owner agency team members
-- ============================================================================
UPDATE public.team
SET include_in_team_checkins = true
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND category = 'agency'
  AND archived_at IS NULL
  AND is_test_user IS NOT TRUE
  AND role_level != 'Owner'
  AND (include_in_team_checkins IS NULL OR include_in_team_checkins = false);

-- ============================================================================
-- 2. Helper: compute required notice in days for a given request
-- ============================================================================
CREATE OR REPLACE FUNCTION public.time_off_required_notice_days(
  p_request_type text,
  p_start_date date,
  p_end_date date
) RETURNS integer AS $$
DECLARE
  v_full_day_count integer;
BEGIN
  -- Half-day requests: 1 day notice
  IF p_request_type IN ('pto_half_day', 'remote_half_day') THEN
    RETURN 1;
  END IF;

  -- 4-day off-day change: 1 week notice (same as a single full day)
  IF p_request_type = 'four_day_off_change' THEN
    RETURN 7;
  END IF;

  -- Full-day requests: 1 week per full day (literal reading)
  v_full_day_count := (p_end_date - p_start_date) + 1;
  RETURN v_full_day_count * 7;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- 3. Notice check
-- ============================================================================
CREATE OR REPLACE FUNCTION public.time_off_check_notice(
  p_request_type text,
  p_submitted_at timestamptz,
  p_start_date date
) RETURNS jsonb AS $$
DECLARE
  v_required_days integer;
  v_provided_days integer;
  v_passes boolean;
BEGIN
  v_required_days := time_off_required_notice_days(p_request_type, p_start_date, p_start_date);
  v_provided_days := p_start_date - p_submitted_at::date;
  v_passes := v_provided_days >= v_required_days;

  RETURN jsonb_build_object(
    'passes', v_passes,
    'required_days', v_required_days,
    'provided_days', v_provided_days,
    'shortfall_days', GREATEST(0, v_required_days - v_provided_days)
  );
END;
$$ LANGUAGE plpgsql STABLE;

-- Overload for full multi-day requests
CREATE OR REPLACE FUNCTION public.time_off_check_notice(
  p_request_type text,
  p_submitted_at timestamptz,
  p_start_date date,
  p_end_date date
) RETURNS jsonb AS $$
DECLARE
  v_required_days integer;
  v_provided_days integer;
  v_passes boolean;
BEGIN
  v_required_days := time_off_required_notice_days(p_request_type, p_start_date, p_end_date);
  v_provided_days := p_start_date - p_submitted_at::date;
  v_passes := v_provided_days >= v_required_days;

  RETURN jsonb_build_object(
    'passes', v_passes,
    'required_days', v_required_days,
    'provided_days', v_provided_days,
    'shortfall_days', GREATEST(0, v_required_days - v_provided_days)
  );
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 4. Eligibility check (TRUE PAY gracefully degraded)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.time_off_check_eligibility(
  p_requester_team_id uuid
) RETURNS jsonb AS $$
DECLARE
  v_team RECORD;
  v_weeks_employed integer;
  v_is_post_probation boolean;
  v_is_account_manager boolean;
  v_is_account_associate boolean;
  v_is_owner boolean;
  v_overall text;
  v_reasons text[] := ARRAY[]::text[];
BEGIN
  SELECT first_name, last_name, role, role_level, hire_date, category, archived_at
    INTO v_team
    FROM public.team
   WHERE id = p_requester_team_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'overall_eligibility', 'ineligible',
      'reasons', ARRAY['team member not found']
    );
  END IF;

  IF v_team.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'overall_eligibility', 'ineligible',
      'reasons', ARRAY['team member is archived']
    );
  END IF;

  -- Probation: 13 weeks = 91 days from hire_date
  v_weeks_employed := CASE
    WHEN v_team.hire_date IS NULL THEN 0
    ELSE FLOOR((CURRENT_DATE - v_team.hire_date) / 7.0)::integer
  END;
  v_is_post_probation := v_weeks_employed >= 13;

  v_is_account_manager := COALESCE(v_team.role_level, '') = 'Account Manager';
  v_is_account_associate := COALESCE(v_team.role_level, '') = 'Account Associate';
  v_is_owner := COALESCE(v_team.role_level, '') = 'Owner';

  -- Owner: always eligible (Peter handles his own time however he wants)
  IF v_is_owner THEN
    v_overall := 'eligible';
  -- Account Manager + post-probation: unlimited PTO eligible, gated on TRUE PAY (deferred)
  ELSIF v_is_account_manager AND v_is_post_probation THEN
    v_overall := 'pending_review';
    v_reasons := array_append(v_reasons,
      'TRUE PAY rating check not yet implemented — manual review by agent required to confirm Good+ rating');
  -- Account Manager in probation: case-by-case
  ELSIF v_is_account_manager AND NOT v_is_post_probation THEN
    v_overall := 'pending_review';
    v_reasons := array_append(v_reasons,
      'Account Manager in 13-week probation (' || v_weeks_employed || ' of 13 weeks) — case-by-case approval required');
  -- Account Associate: accrued PTO model
  ELSIF v_is_account_associate THEN
    v_overall := 'pending_review';
    v_reasons := array_append(v_reasons,
      'Account Associate uses accrued PTO model (5 days year 1, 10/year after) — balance check not yet implemented, manual review required');
  ELSE
    v_overall := 'pending_review';
    v_reasons := array_append(v_reasons,
      'Role level "' || COALESCE(v_team.role_level, 'unknown') || '" not mapped to PTO eligibility — manual review required');
  END IF;

  RETURN jsonb_build_object(
    'overall_eligibility', v_overall,
    'is_owner', v_is_owner,
    'is_account_manager', v_is_account_manager,
    'is_account_associate', v_is_account_associate,
    'is_post_probation', v_is_post_probation,
    'weeks_employed', v_weeks_employed,
    'true_pay_status', 'pending_implementation',
    'reasons', v_reasons,
    'team_name', v_team.first_name || ' ' || v_team.last_name,
    'role_level', v_team.role_level
  );
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 5. Coverage check (runs configured rules against approved/voting requests
--    that overlap the requested date range)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.time_off_check_coverage(
  p_agency_id uuid,
  p_start_date date,
  p_end_date date,
  p_exclude_request_id uuid DEFAULT NULL,
  p_request_type text DEFAULT NULL,
  p_requester_team_id uuid DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_active_team_count integer;
  v_overlapping_off integer;
  v_overlapping_off_aa integer;
  v_overlapping_off_acquisition_am integer;
  v_severity text := 'green';
  v_messages text[] := ARRAY[]::text[];
BEGIN
  -- Active agency team count (the universe)
  SELECT COUNT(*) INTO v_active_team_count
  FROM public.team
  WHERE agency_id = p_agency_id
    AND category = 'agency'
    AND archived_at IS NULL
    AND is_test_user IS NOT TRUE
    AND role_level != 'Owner';

  -- Other team members already off (approved or in voting) overlapping the requested range
  WITH overlapping AS (
    SELECT t.role, t.role_level, t.first_name, t.last_name, r.start_date, r.end_date, r.request_type
    FROM public.time_off_requests r
    JOIN public.team t ON t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status IN ('approved', 'voting', 'awaiting_decision')
      AND r.id IS DISTINCT FROM p_exclude_request_id
      AND r.requester_team_id IS DISTINCT FROM p_requester_team_id
      AND tsrange(r.start_date::timestamp, (r.end_date + 1)::timestamp, '[)')
          && tsrange(p_start_date::timestamp, (p_end_date + 1)::timestamp, '[)')
      AND r.request_type IN ('pto_full_day','pto_half_day','sick','remote_day','remote_half_day')
  )
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE role_level = 'Account Associate'),
    COUNT(*) FILTER (WHERE role_level = 'Account Manager' AND role = 'Acquisition')
  INTO v_overlapping_off, v_overlapping_off_aa, v_overlapping_off_acquisition_am
  FROM overlapping;

  -- Rule 1 (red): At least one team member in office
  IF v_active_team_count - v_overlapping_off - 1 < 1 THEN
    v_severity := 'red';
    v_messages := array_append(v_messages,
      'RED: Approving would leave zero team members in office during business hours');
  END IF;

  -- Rule 2 (yellow): Both Account Associates off → no reception coverage
  IF v_overlapping_off_aa >= 1
     AND p_request_type IN ('pto_full_day','pto_half_day','sick','remote_day','remote_half_day')
     AND EXISTS (
       SELECT 1 FROM public.team
       WHERE id = p_requester_team_id AND role_level = 'Account Associate'
     ) THEN
    IF v_severity = 'green' THEN v_severity := 'yellow'; END IF;
    v_messages := array_append(v_messages,
      'YELLOW: Both Account Associates would be off — no primary/secondary reception coverage');
  END IF;

  -- Rule 3 (yellow): 2+ Acquisition AMs off same week
  IF v_overlapping_off_acquisition_am >= 1
     AND p_request_type IN ('pto_full_day','pto_half_day','sick','remote_day','remote_half_day')
     AND EXISTS (
       SELECT 1 FROM public.team
       WHERE id = p_requester_team_id
         AND role_level = 'Account Manager'
         AND role = 'Acquisition'
     ) THEN
    IF v_severity = 'green' THEN v_severity := 'yellow'; END IF;
    v_messages := array_append(v_messages,
      'YELLOW: Multiple Acquisition AMs off the same week — weekly QUOTE pace at risk');
  END IF;

  RETURN jsonb_build_object(
    'severity', v_severity,
    'messages', v_messages,
    'active_team_count', v_active_team_count,
    'overlapping_off_total', v_overlapping_off,
    'overlapping_off_account_associates', v_overlapping_off_aa,
    'overlapping_off_acquisition_ams', v_overlapping_off_acquisition_am
  );
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 6. Vote status (tally + threshold + quorum)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.time_off_vote_status(
  p_request_id uuid
) RETURNS jsonb AS $$
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

  -- Eligible voters = active agency members minus the requester
  SELECT COUNT(*) INTO v_eligible_voter_count
  FROM public.team
  WHERE agency_id = v_request.agency_id
    AND category = 'agency'
    AND archived_at IS NULL
    AND is_test_user IS NOT TRUE
    AND id IS DISTINCT FROM v_request.requester_team_id;

  -- Tally
  SELECT
    COUNT(*) FILTER (WHERE vote = 'yes'),
    COUNT(*) FILTER (WHERE vote = 'no'),
    COUNT(*) FILTER (WHERE vote = 'abstain'),
    COUNT(*)
  INTO v_yes_count, v_no_count, v_abstain_count, v_votes_cast
  FROM public.time_off_votes
  WHERE request_id = p_request_id;

  -- Quorum: 50% of eligible voters
  v_quorum_threshold := CEIL(v_eligible_voter_count / 2.0)::integer;
  v_quorum_met := v_votes_cast >= v_quorum_threshold;

  -- Simple majority of yes/no votes (abstain excluded from threshold)
  v_simple_majority_yes := (v_yes_count + v_no_count) > 0
    AND v_yes_count > v_no_count;

  -- Recommendation
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
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 7. View: pending vote requests for a given voter
-- ============================================================================
CREATE OR REPLACE VIEW public.v_time_off_pending_votes AS
SELECT
  r.id AS request_id,
  r.agency_id,
  r.requester_team_id,
  req_t.first_name || ' ' || req_t.last_name AS requester_name,
  req_t.role_level AS requester_role_level,
  r.request_type,
  r.start_date,
  r.end_date,
  r.partial_day,
  r.notes,
  r.vote_opened_at,
  r.vote_closes_at,
  r.coverage_check_result,
  voter.id AS voter_team_id,
  voter.first_name || ' ' || voter.last_name AS voter_name,
  EXISTS (
    SELECT 1 FROM public.time_off_votes v
    WHERE v.request_id = r.id AND v.voter_team_id = voter.id
  ) AS already_voted
FROM public.time_off_requests r
JOIN public.team req_t ON req_t.id = r.requester_team_id
CROSS JOIN LATERAL (
  SELECT id, first_name, last_name
  FROM public.team
  WHERE agency_id = r.agency_id
    AND category = 'agency'
    AND archived_at IS NULL
    AND is_test_user IS NOT TRUE
    AND id != r.requester_team_id
) voter
WHERE r.status = 'voting'
  AND (r.vote_closes_at IS NULL OR r.vote_closes_at > NOW());
