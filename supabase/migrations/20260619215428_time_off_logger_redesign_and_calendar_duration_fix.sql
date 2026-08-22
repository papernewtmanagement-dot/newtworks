-- A. Two new columns: paid/unpaid + planned/unplanned (nullable until backfilled)
ALTER TABLE public.time_off_requests
  ADD COLUMN IF NOT EXISTS is_paid    boolean,
  ADD COLUMN IF NOT EXISTS is_planned boolean;

COMMENT ON COLUMN public.time_off_requests.is_paid IS 'TRUE = paid time off, FALSE = unpaid. NULL = pre-redesign rows.';
COMMENT ON COLUMN public.time_off_requests.is_planned IS 'TRUE = planned ahead, FALSE = unplanned (sick, emergency). NULL = pre-redesign rows.';

-- B. Calendar create function — three real bugs:
--    1. send_updates must be enum string, not boolean.
--    2. Composio silently ignores end_datetime; must use event_duration_hour + event_duration_minutes.
--    3. exclude_organizer=true so the calendar service account doesn't get added as an attendee.
CREATE OR REPLACE FUNCTION public.time_off_create_calendar_event(p_agency_id uuid, p_calendar_id text, p_summary text, p_description text, p_start_datetime timestamp with time zone, p_end_datetime timestamp with time zone, p_attendee_emails text[])
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_api_key text;
  v_user_id text;
  v_connected_account_id text;
  v_pg_net_id bigint;
  v_attendees jsonb := '[]'::jsonb;
  v_email text;
  v_duration_seconds bigint;
  v_duration_hours   integer;
  v_duration_minutes integer;
BEGIN
  SELECT setting_value INTO v_api_key
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_user_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_connected_account_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_googlecalendar_account_id';

  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Google Calendar config missing in settings';
  END IF;

  IF p_attendee_emails IS NOT NULL THEN
    FOREACH v_email IN ARRAY p_attendee_emails LOOP
      IF v_email IS NOT NULL AND v_email <> '' THEN
        v_attendees := v_attendees || to_jsonb(v_email);
      END IF;
    END LOOP;
  END IF;

  -- Composio v3 honors event_duration_hour + event_duration_minutes; ignores end_datetime
  v_duration_seconds := EXTRACT(EPOCH FROM (p_end_datetime - p_start_datetime))::bigint;
  v_duration_hours   := (v_duration_seconds / 3600)::integer;
  v_duration_minutes := ((v_duration_seconds % 3600) / 60)::integer;
  IF v_duration_minutes > 59 THEN v_duration_minutes := 59; END IF;
  IF v_duration_hours = 0 AND v_duration_minutes = 0 THEN v_duration_minutes := 30; END IF;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/GOOGLECALENDAR_CREATE_EVENT',
    headers := jsonb_build_object(
      'x-api-key',    v_api_key,
      'Content-Type', 'application/json'
    ),
    body    := jsonb_build_object(
      'user_id',              v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments', jsonb_build_object(
        'calendar_id',            p_calendar_id,
        'summary',                p_summary,
        'description',            p_description,
        'start_datetime',         to_char(p_start_datetime AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
        'timezone',               'America/Chicago',
        'event_duration_hour',    v_duration_hours,
        'event_duration_minutes', v_duration_minutes,
        'attendees',              v_attendees,
        'create_meeting_room',    false,
        'exclude_organizer',      true,
        'send_updates',           'none'
      )
    )
  ) INTO v_pg_net_id;

  RETURN v_pg_net_id;
END;
$function$;

-- C. Calendar dispatcher — add second pass to capture event_id from response
CREATE OR REPLACE FUNCTION public.time_off_calendar_dispatch(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_events_created      int := 0;
  v_events_skipped      int := 0;
  v_event_ids_captured  int := 0;
  v_req RECORD;
  v_pg_net_id bigint;
  v_calendar_id text;
  v_calendar_name text;
  v_summary text;
  v_description text;
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_attendees text[];
  v_type_label text;
  v_event_id text;
  v_bcc_url text := 'https://storybccdashboard.vercel.app';
  v_cal_time_off text := '9b19aaadf951b1018ea03643a530030a44c6029be887426f892ae85fccfce156@group.calendar.google.com';
  v_cal_location text := 'ece83179e486bdfe5c7c736c7ccc7fec577ea25a8e46fe5c76a2dc25fb615c41@group.calendar.google.com';
BEGIN
  -- PASS 1: create events for newly-approved requests
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.partial_day,
           r.notes, r.decision_note, r.proposed_four_day_off_day,
           r.is_paid, r.is_planned, r.requester_team_id,
           req_t.first_name, req_t.last_name, req_t.work_location,
           COALESCE(req_t.email_sf, req_t.email_personal) AS requester_email
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status = 'approved'
      AND r.calendar_dispatched_at IS NULL
  LOOP
    IF v_req.request_type IN ('pto_full_day', 'pto_half_day', 'sick', 'four_day_off_change') THEN
      v_calendar_id := v_cal_time_off;
      v_calendar_name := 'Story Agency — Time Off';
      v_type_label := CASE v_req.request_type
        WHEN 'pto_full_day' THEN 'PTO'
        WHEN 'pto_half_day' THEN 'PTO (half day)'
        WHEN 'sick' THEN 'Sick'
        WHEN 'four_day_off_change' THEN '4-day off → ' || COALESCE(v_req.proposed_four_day_off_day, '?')
      END;
    ELSIF v_req.request_type IN ('remote_day', 'remote_half_day') THEN
      IF v_req.work_location = 'remote' THEN
        UPDATE public.time_off_requests
        SET calendar_dispatched_at = NOW(),
            calendar_name = '(skipped — requester is already default remote)'
        WHERE id = v_req.id;
        v_events_skipped := v_events_skipped + 1;
        CONTINUE;
      END IF;
      v_calendar_id := v_cal_location;
      v_calendar_name := 'Story Agency — Location';
      v_type_label := CASE v_req.request_type
        WHEN 'remote_day' THEN 'Remote'
        WHEN 'remote_half_day' THEN 'Remote (half day)'
      END;
    ELSE
      UPDATE public.time_off_requests
      SET calendar_dispatched_at = NOW(),
          calendar_name = '(skipped — unknown request_type: ' || v_req.request_type || ')'
      WHERE id = v_req.id;
      v_events_skipped := v_events_skipped + 1;
      CONTINUE;
    END IF;

    v_summary := v_req.first_name || ' — ' || v_type_label;

    -- Description includes paid/planned context if known
    v_description := 'Approved time off request' || E'\n\n' ||
                     'Type: ' || v_type_label || E'\n' ||
                     'When: ' || trim(to_char(v_req.start_date, 'Day, Month DD, YYYY'));
    IF v_req.start_date <> v_req.end_date THEN
      v_description := v_description || ' → ' || trim(to_char(v_req.end_date, 'Day, Month DD, YYYY'));
    END IF;
    IF v_req.is_paid IS NOT NULL THEN
      v_description := v_description || E'\nPay: ' || CASE WHEN v_req.is_paid THEN 'Paid' ELSE 'Unpaid' END;
    END IF;
    IF v_req.is_planned IS NOT NULL THEN
      v_description := v_description || E'\nPlanning: ' || CASE WHEN v_req.is_planned THEN 'Planned' ELSE 'Unplanned' END;
    END IF;
    IF v_req.notes IS NOT NULL THEN
      v_description := v_description || E'\n\nRequester notes: ' || v_req.notes;
    END IF;
    IF v_req.decision_note IS NOT NULL THEN
      v_description := v_description || E'\n\nApproval note: ' || v_req.decision_note;
    END IF;
    v_description := v_description || E'\n\nManaged via BCC: ' || v_bcc_url;

    IF v_req.partial_day = 'morning' THEN
      v_start_ts := (v_req.start_date::text || ' 08:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 12:00:00')::timestamp AT TIME ZONE 'America/Chicago';
    ELSIF v_req.partial_day = 'afternoon' THEN
      v_start_ts := (v_req.start_date::text || ' 13:00:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 17:30:00')::timestamp AT TIME ZONE 'America/Chicago';
    ELSE
      v_start_ts := (v_req.start_date::text || ' 08:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.end_date::text   || ' 17:30:00')::timestamp AT TIME ZONE 'America/Chicago';
    END IF;

    v_attendees := CASE WHEN v_req.requester_email IS NOT NULL AND v_req.requester_email <> ''
                        THEN ARRAY[v_req.requester_email] ELSE ARRAY[]::text[] END;

    v_pg_net_id := public.time_off_create_calendar_event(
      p_agency_id, v_calendar_id, v_summary, v_description,
      v_start_ts, v_end_ts, v_attendees
    );

    UPDATE public.time_off_requests
    SET calendar_dispatched_at = NOW(),
        calendar_pg_net_request_id = v_pg_net_id,
        calendar_name = v_calendar_name
    WHERE id = v_req.id;

    v_events_created := v_events_created + 1;
  END LOOP;

  -- PASS 2: capture event_id from prior dispatches now that responses are available
  FOR v_req IN
    SELECT r.id, r.calendar_pg_net_request_id
    FROM public.time_off_requests r
    WHERE r.agency_id = p_agency_id
      AND r.calendar_event_id IS NULL
      AND r.calendar_pg_net_request_id IS NOT NULL
      AND r.calendar_dispatched_at IS NOT NULL
      AND r.calendar_dispatched_at > NOW() - INTERVAL '48 hours'
  LOOP
    SELECT (resp.content::jsonb)#>>'{data,response_data,id}'
    INTO v_event_id
    FROM net._http_response resp
    WHERE resp.id = v_req.calendar_pg_net_request_id;

    IF v_event_id IS NOT NULL AND v_event_id <> '' THEN
      UPDATE public.time_off_requests
      SET calendar_event_id = v_event_id
      WHERE id = v_req.id;
      v_event_ids_captured := v_event_ids_captured + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'events_created',     v_events_created,
    'events_skipped',     v_events_skipped,
    'event_ids_captured', v_event_ids_captured,
    'dispatched_at',      NOW()
  );
END;
$function$;

-- D. Replace log_sick_day_for with log_time_off_for (generic — any request_type, paid/planned flags)
DROP FUNCTION IF EXISTS public.log_sick_day_for(uuid, date, date, text, text);

CREATE OR REPLACE FUNCTION public.log_time_off_for(
  p_team_member_id uuid,
  p_request_type   text,
  p_start_date     date,
  p_end_date       date    DEFAULT NULL,
  p_partial_day    text    DEFAULT 'none',
  p_is_paid        boolean DEFAULT true,
  p_is_planned     boolean DEFAULT false,
  p_notes          text    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller_team_id uuid;
  v_caller_role    text;
  v_caller_agency  uuid;
  v_target_agency  uuid;
  v_request_id     uuid;
BEGIN
  -- Caller identity + role check
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

  -- Validate request_type
  IF p_request_type NOT IN ('sick', 'pto_full_day', 'pto_half_day', 'remote_day', 'remote_half_day') THEN
    RAISE EXCEPTION 'log_time_off_for: invalid request_type %', p_request_type;
  END IF;

  -- Validate partial_day matches request_type semantics
  IF p_request_type IN ('pto_full_day', 'remote_day') AND COALESCE(p_partial_day, 'none') <> 'none' THEN
    RAISE EXCEPTION 'log_time_off_for: % requires partial_day=none', p_request_type;
  END IF;
  IF p_request_type IN ('pto_half_day', 'remote_half_day') AND COALESCE(p_partial_day, 'none') NOT IN ('morning', 'afternoon') THEN
    RAISE EXCEPTION 'log_time_off_for: % requires partial_day=morning or afternoon', p_request_type;
  END IF;

  -- Verify target team member in same agency
  SELECT agency_id INTO v_target_agency
  FROM public.team
  WHERE id = p_team_member_id AND archived_at IS NULL
  LIMIT 1;

  IF v_target_agency IS NULL OR v_target_agency <> v_caller_agency THEN
    RAISE EXCEPTION 'log_time_off_for: target team member not found or not in caller''s agency';
  END IF;

  -- Insert as auto-approved, skip vote+email, calendar dispatcher will pick up
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

GRANT EXECUTE ON FUNCTION public.log_time_off_for(uuid, text, date, date, text, boolean, boolean, text) TO authenticated;
