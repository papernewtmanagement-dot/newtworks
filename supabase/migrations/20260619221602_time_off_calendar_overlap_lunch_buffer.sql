-- Half-day cuts use lunch-buffer overlap model (per Peter, 2026-06-19):
--   Morning off:   08:30 AM - 1:30 PM  (5h — work + lunch + 30 min buffer)
--   Afternoon off: 12:30 PM - 5:30 PM  (5h — 30 min before lunch + lunch + work)
--   Full day:      08:30 AM - 5:30 PM  (9h, unchanged)
-- Visually shows literal "person is gone from desk" rather than "PTO clock running."
-- 12:30-1:30 PM overlap is intentional (the lunch hour is owned by both halves).
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

    -- Times: overlap-at-lunch model
    IF v_req.partial_day = 'morning' THEN
      v_start_ts := (v_req.start_date::text || ' 08:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 13:30:00')::timestamp AT TIME ZONE 'America/Chicago';
    ELSIF v_req.partial_day = 'afternoon' THEN
      v_start_ts := (v_req.start_date::text || ' 12:30:00')::timestamp AT TIME ZONE 'America/Chicago';
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

  -- Pass 2: event_id capture
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

-- Update catalog reference to match new times
UPDATE public.persistent_memory
SET content = REPLACE(content,
  'Times: full day 08:30-17:30 CT, morning 08:30-13:00 (cut at 1 PM, lunch hour falls in morning), afternoon 13:00-17:30.',
  'Times: full day 08:30-17:30 CT, morning 08:30-13:30 (5h with lunch buffer), afternoon 12:30-17:30 (5h with lunch buffer). 12:30-13:30 overlap is intentional — represents literal "absent from desk" including lunch grabbed out, not PTO hours consumed.'
),
updated_at = NOW()
WHERE id = 'f9f8c772-291e-40e7-96c1-a27a81ff9a81';
