-- SECURITY DEFINER function: owner-only, log a sick day on behalf of a team member.
-- Inserts time_off_request with status='approved', skips vote, no email, calendar
-- event will be picked up by the existing pg_cron calendar dispatcher.
CREATE OR REPLACE FUNCTION public.log_sick_day_for(
  p_team_member_id uuid,
  p_start_date date,
  p_end_date date DEFAULT NULL,
  p_partial_day text DEFAULT 'none',
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_team_id uuid;
  v_caller_role    text;
  v_caller_agency  uuid;
  v_target_agency  uuid;
  v_request_id     uuid;
BEGIN
  -- Identify the caller via their auth.uid()
  SELECT u.team_member_id, u.role, u.agency_id
  INTO v_caller_team_id, v_caller_role, v_caller_agency
  FROM public.users u
  WHERE u.auth_user_id = auth.uid()
  LIMIT 1;

  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'log_sick_day_for: caller has no users row (auth_user_id=%)', auth.uid();
  END IF;

  IF v_caller_role <> 'owner' THEN
    RAISE EXCEPTION 'log_sick_day_for: only the owner can log sick days on behalf of team members (caller role=%)', v_caller_role;
  END IF;

  -- Verify the target team member is in the same agency and active
  SELECT agency_id INTO v_target_agency
  FROM public.team
  WHERE id = p_team_member_id AND archived_at IS NULL
  LIMIT 1;

  IF v_target_agency IS NULL OR v_target_agency <> v_caller_agency THEN
    RAISE EXCEPTION 'log_sick_day_for: target team member not found or not in caller''s agency';
  END IF;

  -- Insert with status='approved', dispatcher-skip flags for email
  -- (decision_notified_at = NOW() prevents the decision email dispatcher from firing).
  -- calendar_event_id / calendar_dispatched_at left NULL so the calendar dispatcher
  -- picks it up and creates the calendar event.
  INSERT INTO public.time_off_requests (
    agency_id,
    requester_team_id,
    request_type,
    status,
    start_date,
    end_date,
    partial_day,
    notes,
    submitted_at,
    decided_at,
    decided_by_team_id,
    decision_note,
    decision_notified_at,
    eligibility_check_result,
    notice_check_result,
    coverage_check_result
  )
  VALUES (
    v_caller_agency,
    p_team_member_id,
    'sick',
    'approved',
    p_start_date,
    COALESCE(p_end_date, p_start_date),
    COALESCE(p_partial_day, 'none'),
    p_notes,
    NOW(),
    NOW(),
    v_caller_team_id,
    'Logged by owner on team member''s behalf (sick day, vote skipped, no email sent)',
    NOW(),
    jsonb_build_object('overall_eligibility', 'bypassed', 'reason', 'sick day logged by owner'),
    jsonb_build_object('passes', true, 'reason', 'sick day logged by owner'),
    jsonb_build_object('severity', 'none', 'messages', '[]'::jsonb)
  )
  RETURNING id INTO v_request_id;

  RETURN v_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_sick_day_for(uuid, date, date, text, text) TO authenticated;
