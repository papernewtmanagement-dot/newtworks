-- Migration: rename pto_full_day / pto_half_day → time_off_full_day / time_off_half_day
-- Rationale: "PTO" implies paid time off, but not all time off is paid (is_paid boolean handles that).
-- Applied via Supabase MCP 2026-07-13; mirrored to repo per standing rule.
--
-- Note: log_time_off_for + time_off_required_notice_days + time_off_check_coverage +
-- time_off_calendar_dispatch were rewritten in the same migration to use the new enum values.
-- time_off_calendar_dispatch was then superseded by 20260713162526_time_off_labels_paid_aware.sql
-- (which routes labels through the paid-aware helper).

-- 1) Expand CHECK to accept both old + new (transitional)
ALTER TABLE public.time_off_requests
  DROP CONSTRAINT time_off_requests_request_type_check;

ALTER TABLE public.time_off_requests
  ADD CONSTRAINT time_off_requests_request_type_check
  CHECK (request_type = ANY (ARRAY[
    'pto_full_day'::text, 'pto_half_day'::text,
    'time_off_full_day'::text, 'time_off_half_day'::text,
    'sick'::text, 'remote_day'::text, 'remote_half_day'::text,
    'four_day_off_change'::text
  ]));

-- 2) Rename data rows
UPDATE public.time_off_requests SET request_type = 'time_off_full_day' WHERE request_type = 'pto_full_day';
UPDATE public.time_off_requests SET request_type = 'time_off_half_day' WHERE request_type = 'pto_half_day';

-- 3) Restrict CHECK to new values only
ALTER TABLE public.time_off_requests
  DROP CONSTRAINT time_off_requests_request_type_check;

ALTER TABLE public.time_off_requests
  ADD CONSTRAINT time_off_requests_request_type_check
  CHECK (request_type = ANY (ARRAY[
    'time_off_full_day'::text, 'time_off_half_day'::text,
    'sick'::text, 'remote_day'::text, 'remote_half_day'::text,
    'four_day_off_change'::text
  ]));

-- 4) log_time_off_for — accept new enum values only
CREATE OR REPLACE FUNCTION public.log_time_off_for(p_team_member_id uuid, p_request_type text, p_start_date date, p_end_date date DEFAULT NULL::date, p_partial_day text DEFAULT 'none'::text, p_is_paid boolean DEFAULT true, p_is_planned boolean DEFAULT false, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_team_id uuid;
  v_caller_role    text;
  v_caller_agency  uuid;
  v_target_agency  uuid;
  v_request_id     uuid;
BEGIN
  SELECT u.team_member_id, u.role, u.agency_id
  INTO v_caller_team_id, v_caller_role, v_caller_agency
  FROM public.users u
  WHERE u.auth_user_id = auth.uid()
  LIMIT 1;

  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'log_time_off_for: caller has no users row (auth_user_id=%)', auth.uid();
  END IF;

  IF v_caller_role <> 'owner' THEN
    RAISE EXCEPTION 'log_time_off_for: only the owner can log time off on behalf of team members (caller role=%)', v_caller_role;
  END IF;

  IF p_request_type NOT IN ('sick', 'time_off_full_day', 'time_off_half_day', 'remote_day', 'remote_half_day') THEN
    RAISE EXCEPTION 'log_time_off_for: invalid request_type %', p_request_type;
  END IF;

  IF p_request_type IN ('time_off_full_day', 'remote_day') AND COALESCE(p_partial_day, 'none') <> 'none' THEN
    RAISE EXCEPTION 'log_time_off_for: % requires partial_day=none', p_request_type;
  END IF;
  IF p_request_type IN ('time_off_half_day', 'remote_half_day') AND COALESCE(p_partial_day, 'none') NOT IN ('morning', 'afternoon') THEN
    RAISE EXCEPTION 'log_time_off_for: % requires partial_day=morning or afternoon', p_request_type;
  END IF;

  SELECT agency_id INTO v_target_agency
  FROM public.team
  WHERE id = p_team_member_id AND archived_at IS NULL
  LIMIT 1;

  IF v_target_agency IS NULL OR v_target_agency <> v_caller_agency THEN
    RAISE EXCEPTION 'log_time_off_for: target team member not found or not in caller''s agency';
  END IF;

  INSERT INTO public.time_off_requests (
    agency_id, requester_team_id, request_type, status,
    start_date, end_date, partial_day, is_paid, is_planned, notes,
    submitted_at, decided_at, decided_by_team_id, decision_note, decision_notified_at,
    eligibility_check_result, notice_check_result, coverage_check_result
  )
  VALUES (
    v_caller_agency, p_team_member_id, p_request_type, 'approved',
    p_start_date, COALESCE(p_end_date, p_start_date), COALESCE(p_partial_day, 'none'),
    p_is_paid, p_is_planned, p_notes,
    NOW(), NOW(), v_caller_team_id,
    'Logged by owner on team member''s behalf (' || p_request_type || ', vote skipped, no email sent)',
    NOW(),
    jsonb_build_object('overall_eligibility', 'bypassed', 'reason', 'logged by owner'),
    jsonb_build_object('passes', true, 'reason', 'logged by owner'),
    jsonb_build_object('severity', 'none', 'messages', '[]'::jsonb)
  )
  RETURNING id INTO v_request_id;

  RETURN v_request_id;
END;
$function$;

-- 5) time_off_required_notice_days
CREATE OR REPLACE FUNCTION public.time_off_required_notice_days(p_request_type text, p_start_date date, p_end_date date)
 RETURNS integer
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_full_day_count integer;
BEGIN
  IF p_request_type IN ('time_off_half_day', 'remote_half_day') THEN
    RETURN 1;
  END IF;

  IF p_request_type = 'four_day_off_change' THEN
    RETURN 7;
  END IF;

  v_full_day_count := (p_end_date - p_start_date) + 1;
  RETURN v_full_day_count * 7;
END;
$function$;

-- 6) time_off_check_coverage
CREATE OR REPLACE FUNCTION public.time_off_check_coverage(p_agency_id uuid, p_start_date date, p_end_date date, p_exclude_request_id uuid DEFAULT NULL::uuid, p_request_type text DEFAULT NULL::text, p_requester_team_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_active_team_count integer;
  v_overlapping_off integer;
  v_overlapping_off_aa integer;
  v_overlapping_off_acquisition_am integer;
  v_severity text := 'green';
  v_messages text[] := ARRAY[]::text[];
BEGIN
  SELECT COUNT(*)::int INTO v_active_team_count
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant');

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
      AND r.request_type IN ('time_off_full_day','time_off_half_day','sick','remote_day','remote_half_day')
  )
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE role_level = 'Account Associate'),
    COUNT(*) FILTER (WHERE role_level = 'Account Manager' AND role = 'Acquisition')
  INTO v_overlapping_off, v_overlapping_off_aa, v_overlapping_off_acquisition_am
  FROM overlapping;

  IF v_active_team_count - v_overlapping_off - 1 < 1 THEN
    v_severity := 'red';
    v_messages := array_append(v_messages,
      'RED: Approving would leave zero team members in office during business hours');
  END IF;

  IF v_overlapping_off_aa >= 1
     AND p_request_type IN ('time_off_full_day','time_off_half_day','sick','remote_day','remote_half_day')
     AND EXISTS (SELECT 1 FROM public.team WHERE id = p_requester_team_id AND role_level = 'Account Associate') THEN
    IF v_severity = 'green' THEN v_severity := 'yellow'; END IF;
    v_messages := array_append(v_messages,
      'YELLOW: Both Account Associates would be off — no primary/secondary reception coverage');
  END IF;

  IF v_overlapping_off_acquisition_am >= 1
     AND p_request_type IN ('time_off_full_day','time_off_half_day','sick','remote_day','remote_half_day')
     AND EXISTS (SELECT 1 FROM public.team WHERE id = p_requester_team_id AND role_level = 'Account Manager' AND role = 'Acquisition') THEN
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
$function$;

-- 7) time_off_calendar_dispatch — new-enum values only
-- NOTE: superseded by 20260713162526_time_off_labels_paid_aware.sql which routes labels through the paid-aware helper.
-- Intermediate body (blanket 'Time off' labels) not repeated here — see git history at commit 8df64c9 range.

-- 8) Verify final state
DO $$
DECLARE v_bad int;
BEGIN
  SELECT COUNT(*) INTO v_bad FROM public.time_off_requests WHERE request_type IN ('pto_full_day','pto_half_day');
  IF v_bad > 0 THEN RAISE EXCEPTION 'migration failed: % rows still on old enum values', v_bad; END IF;
END $$;
