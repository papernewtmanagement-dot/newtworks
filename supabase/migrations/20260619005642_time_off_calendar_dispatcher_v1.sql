-- ============================================================================
-- Step D: Time off calendar event dispatcher
-- On approval, create a Google Calendar event on Time Off or Location calendar
-- ============================================================================

-- 1. Tracking columns
ALTER TABLE public.time_off_requests
  ADD COLUMN IF NOT EXISTS calendar_dispatched_at      timestamptz,
  ADD COLUMN IF NOT EXISTS calendar_pg_net_request_id  bigint;

-- 2. Calendar-create helper using pg_net + Composio v3
CREATE OR REPLACE FUNCTION public.time_off_create_calendar_event(
  p_agency_id        uuid,
  p_calendar_id      text,
  p_summary          text,
  p_description      text,
  p_start_datetime   timestamptz,
  p_end_datetime     timestamptz,
  p_attendee_emails  text[]
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_api_key text;
  v_user_id text;
  v_connected_account_id text;
  v_pg_net_id bigint;
  v_attendees jsonb := '[]'::jsonb;
  v_email text;
BEGIN
  SELECT setting_value INTO v_api_key
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';

  SELECT setting_value INTO v_user_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';

  SELECT setting_value INTO v_connected_account_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_googlecalendar_account_id';

  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Google Calendar config missing in settings (api_key=%, user_id=%, connected_account_id=%)',
      v_api_key IS NOT NULL, v_user_id IS NOT NULL, v_connected_account_id IS NOT NULL;
  END IF;

  IF p_attendee_emails IS NOT NULL THEN
    FOREACH v_email IN ARRAY p_attendee_emails LOOP
      IF v_email IS NOT NULL AND v_email <> '' THEN
        v_attendees := v_attendees || to_jsonb(v_email);
      END IF;
    END LOOP;
  END IF;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/GOOGLECALENDAR_CREATE_EVENT',
    headers := jsonb_build_object(
      'x-api-key', v_api_key,
      'Content-Type', 'application/json'
    ),
    body    := jsonb_build_object(
      'user_id', v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments', jsonb_build_object(
        'calendar_id',         p_calendar_id,
        'summary',             p_summary,
        'description',         p_description,
        'start_datetime',      to_char(p_start_datetime AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
        'end_datetime',        to_char(p_end_datetime   AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
        'timezone',            'America/Chicago',
        'attendees',           v_attendees,
        'create_meeting_room', false,
        'send_updates',        'all'
      )
    )
  ) INTO v_pg_net_id;

  RETURN v_pg_net_id;
END;
$func$;

REVOKE EXECUTE ON FUNCTION public.time_off_create_calendar_event(uuid, text, text, text, timestamptz, timestamptz, text[]) FROM PUBLIC, anon, authenticated;

-- 3. Calendar dispatcher
CREATE OR REPLACE FUNCTION public.time_off_calendar_dispatch(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_events_created int := 0;
  v_events_skipped int := 0;
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
  v_bcc_url text := 'https://storybccdashboard.vercel.app';
  -- Calendar IDs (persistent_memory id f23ffb15-028c-4236-b846-0cf2379f3997)
  v_cal_time_off text := '9b19aaadf951b1018ea03643a530030a44c6029be887426f892ae85fccfce156@group.calendar.google.com';
  v_cal_location text := 'ece83179e486bdfe5c7c736c7ccc7fec577ea25a8e46fe5c76a2dc25fb615c41@group.calendar.google.com';
BEGIN
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.partial_day,
           r.notes, r.decision_note, r.proposed_four_day_off_day,
           r.requester_team_id,
           req_t.first_name, req_t.last_name, req_t.work_location,
           COALESCE(req_t.email_personal, req_t.email_sf) AS requester_email
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status = 'approved'
      AND r.calendar_dispatched_at IS NULL
  LOOP

    -- Calendar routing
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
      -- Skip if requester is already default remote (no deviation)
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

    -- Title: "First Name — Type"
    v_summary := v_req.first_name || ' — ' || v_type_label;

    -- Description (plain text — Calendar handles HTML poorly in description)
    v_description := 'Approved time off request' || E'\n\n' ||
                     'Type: ' || v_type_label || E'\n' ||
                     'When: ' || trim(to_char(v_req.start_date, 'Day, Month DD, YYYY'));
    IF v_req.start_date <> v_req.end_date THEN
      v_description := v_description || ' → ' || trim(to_char(v_req.end_date, 'Day, Month DD, YYYY'));
    END IF;
    IF v_req.notes IS NOT NULL THEN
      v_description := v_description || E'\n\nRequester notes: ' || v_req.notes;
    END IF;
    IF v_req.decision_note IS NOT NULL THEN
      v_description := v_description || E'\n\nApproval note: ' || v_req.decision_note;
    END IF;
    v_description := v_description || E'\n\nManaged via BCC: ' || v_bcc_url;

    -- Datetime ranges (Chicago wall-clock)
    IF v_req.partial_day = 'morning' THEN
      v_start_ts := (v_req.start_date::text || ' 08:00:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 12:00:00')::timestamp AT TIME ZONE 'America/Chicago';
    ELSIF v_req.partial_day = 'afternoon' THEN
      v_start_ts := (v_req.start_date::text || ' 13:00:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 17:00:00')::timestamp AT TIME ZONE 'America/Chicago';
    ELSE
      -- Full day(s): midnight start to midnight day-after-end
      v_start_ts := (v_req.start_date::text || ' 00:00:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := ((v_req.end_date + 1)::text || ' 00:00:00')::timestamp AT TIME ZONE 'America/Chicago';
    END IF;

    -- Invite the requester
    v_attendees := CASE WHEN v_req.requester_email IS NOT NULL AND v_req.requester_email <> ''
                        THEN ARRAY[v_req.requester_email]
                        ELSE ARRAY[]::text[] END;

    -- Dispatch create event
    v_pg_net_id := public.time_off_create_calendar_event(
      p_agency_id,
      v_calendar_id,
      v_summary,
      v_description,
      v_start_ts,
      v_end_ts,
      v_attendees
    );

    UPDATE public.time_off_requests
    SET calendar_dispatched_at = NOW(),
        calendar_pg_net_request_id = v_pg_net_id,
        calendar_name = v_calendar_name
    WHERE id = v_req.id;

    v_events_created := v_events_created + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'events_created', v_events_created,
    'events_skipped', v_events_skipped,
    'dispatched_at', NOW()
  );
END;
$func$;

REVOKE EXECUTE ON FUNCTION public.time_off_calendar_dispatch(uuid) FROM PUBLIC, anon, authenticated;

-- 4. pg_cron schedule
SELECT cron.schedule(
  'time_off_calendar_dispatch',
  '*/5 * * * *',
  $sql$SELECT public.time_off_calendar_dispatch();$sql$
);

-- 5. Register recipe
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description,
  trigger_type, cron_expression,
  internal_handler, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Time Off Calendar Dispatch',
  'Polls time_off_requests every 5 min for approved requests with calendar_dispatched_at IS NULL. Creates a Google Calendar event on Time Off or Location calendar (routed by request_type, with remote-day-from-already-remote-person skipped). Invites the requester via Composio v3 Google Calendar API. pg_cron + pg_net direct dispatch.',
  'cron',
  '*/5 * * * *',
  'time_off_calendar_dispatch',
  true
);
