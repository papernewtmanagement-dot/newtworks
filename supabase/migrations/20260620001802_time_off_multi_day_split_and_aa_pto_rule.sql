-- A. Convert single-event columns to arrays so one DB row can map to multiple calendar events
ALTER TABLE public.time_off_requests
  ALTER COLUMN calendar_event_id TYPE text[]
  USING CASE WHEN calendar_event_id IS NULL THEN NULL ELSE ARRAY[calendar_event_id] END;

ALTER TABLE public.time_off_requests
  ALTER COLUMN calendar_pg_net_request_id TYPE bigint[]
  USING CASE WHEN calendar_pg_net_request_id IS NULL THEN NULL ELSE ARRAY[calendar_pg_net_request_id] END;

COMMENT ON COLUMN public.time_off_requests.calendar_event_id IS 'One Google event_id per workday for full-day requests (weekends skipped); single element for half-day requests. NULL when nothing dispatched yet.';
COMMENT ON COLUMN public.time_off_requests.calendar_pg_net_request_id IS 'Matching array of pg_net request_ids, one per event_id. Order is parallel to calendar_event_id.';

-- B. Rewrite dispatcher: full-day multi-day → one event per workday (Mon-Fri); half-day unchanged
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
  v_description_base text;
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_attendees text[];
  v_type_label text;
  v_event_id text;
  v_pg_net_ids bigint[];
  v_event_ids  text[];
  v_current_date date;
  v_bcc_url text := 'https://storybccdashboard.vercel.app';
  v_cal_time_off text := '9b19aaadf951b1018ea03643a530030a44c6029be887426f892ae85fccfce156@group.calendar.google.com';
  v_cal_location text := 'ece83179e486bdfe5c7c736c7ccc7fec577ea25a8e46fe5c76a2dc25fb615c41@group.calendar.google.com';
BEGIN
  -- PASS 1: create events
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
    -- Route calendar
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
    v_description_base := 'Approved time off request' || E'\n\n' ||
                          'Type: ' || v_type_label || E'\n' ||
                          'When: ' || trim(to_char(v_req.start_date, 'Day, Month DD, YYYY'));
    IF v_req.start_date <> v_req.end_date THEN
      v_description_base := v_description_base || ' → ' || trim(to_char(v_req.end_date, 'Day, Month DD, YYYY'));
    END IF;
    IF v_req.is_paid IS NOT NULL THEN
      v_description_base := v_description_base || E'\nPay: ' || CASE WHEN v_req.is_paid THEN 'Paid' ELSE 'Unpaid' END;
    END IF;
    IF v_req.is_planned IS NOT NULL THEN
      v_description_base := v_description_base || E'\nPlanning: ' || CASE WHEN v_req.is_planned THEN 'Planned' ELSE 'Unplanned' END;
    END IF;
    IF v_req.notes IS NOT NULL THEN
      v_description_base := v_description_base || E'\n\nRequester notes: ' || v_req.notes;
    END IF;
    IF v_req.decision_note IS NOT NULL THEN
      v_description_base := v_description_base || E'\n\nApproval note: ' || v_req.decision_note;
    END IF;
    v_description_base := v_description_base || E'\n\nManaged via BCC: ' || v_bcc_url;

    v_attendees := CASE WHEN v_req.requester_email IS NOT NULL AND v_req.requester_email <> ''
                        THEN ARRAY[v_req.requester_email] ELSE ARRAY[]::text[] END;

    v_pg_net_ids := ARRAY[]::bigint[];

    IF v_req.partial_day = 'morning' THEN
      v_start_ts := (v_req.start_date::text || ' 08:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 13:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_pg_net_id := public.time_off_create_calendar_event(
        p_agency_id, v_calendar_id, v_summary, v_description_base, v_start_ts, v_end_ts, v_attendees);
      v_pg_net_ids := ARRAY[v_pg_net_id];
      v_events_created := v_events_created + 1;
    ELSIF v_req.partial_day = 'afternoon' THEN
      v_start_ts := (v_req.start_date::text || ' 12:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 17:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_pg_net_id := public.time_off_create_calendar_event(
        p_agency_id, v_calendar_id, v_summary, v_description_base, v_start_ts, v_end_ts, v_attendees);
      v_pg_net_ids := ARRAY[v_pg_net_id];
      v_events_created := v_events_created + 1;
    ELSE
      -- Full day(s): create one event per workday Mon–Fri across [start_date, end_date]
      v_current_date := v_req.start_date;
      WHILE v_current_date <= v_req.end_date LOOP
        IF EXTRACT(DOW FROM v_current_date) BETWEEN 1 AND 5 THEN
          v_start_ts := (v_current_date::text || ' 08:30:00')::timestamp AT TIME ZONE 'America/Chicago';
          v_end_ts   := (v_current_date::text || ' 17:30:00')::timestamp AT TIME ZONE 'America/Chicago';
          v_pg_net_id := public.time_off_create_calendar_event(
            p_agency_id, v_calendar_id, v_summary, v_description_base, v_start_ts, v_end_ts, v_attendees);
          v_pg_net_ids := array_append(v_pg_net_ids, v_pg_net_id);
          v_events_created := v_events_created + 1;
        END IF;
        v_current_date := v_current_date + 1;
      END LOOP;
    END IF;

    UPDATE public.time_off_requests
    SET calendar_dispatched_at = NOW(),
        calendar_pg_net_request_id = v_pg_net_ids,
        calendar_name = v_calendar_name
    WHERE id = v_req.id;
  END LOOP;

  -- PASS 2: capture event_ids from async responses, all-or-nothing per row
  FOR v_req IN
    SELECT r.id, r.calendar_pg_net_request_id
    FROM public.time_off_requests r
    WHERE r.agency_id = p_agency_id
      AND r.calendar_pg_net_request_id IS NOT NULL
      AND (r.calendar_event_id IS NULL
           OR COALESCE(array_length(r.calendar_event_id, 1), 0)
              < COALESCE(array_length(r.calendar_pg_net_request_id, 1), 0))
      AND r.calendar_dispatched_at IS NOT NULL
      AND r.calendar_dispatched_at > NOW() - INTERVAL '48 hours'
  LOOP
    v_event_ids := ARRAY[]::text[];
    FOREACH v_pg_net_id IN ARRAY v_req.calendar_pg_net_request_id LOOP
      SELECT (resp.content::jsonb)#>>'{data,response_data,id}'
      INTO v_event_id
      FROM net._http_response resp
      WHERE resp.id = v_pg_net_id;
      IF v_event_id IS NOT NULL AND v_event_id <> '' THEN
        v_event_ids := array_append(v_event_ids, v_event_id);
      END IF;
    END LOOP;

    IF COALESCE(array_length(v_event_ids, 1), 0)
       = COALESCE(array_length(v_req.calendar_pg_net_request_id, 1), 0)
    THEN
      UPDATE public.time_off_requests
      SET calendar_event_id = v_event_ids
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

-- C. Fix Account Associate PTO accrual rule per handbook (5 days AFTER year 1, 10 days AFTER year 2)
CREATE OR REPLACE FUNCTION public.time_off_check_eligibility(p_requester_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_team                    RECORD;
  v_weeks_employed          integer;
  v_is_post_probation       boolean;
  v_role_level              text;
  v_is_owner                boolean;
  v_is_account_associate    boolean;
  v_is_manager_tier         boolean;
  v_individual_avg          numeric;
  v_individual_rating       text;
  v_individual_passes       boolean;
  v_agency_avg              numeric;
  v_agency_rating           text;
  v_agency_passes           boolean;
  v_overall                 text;
  v_reasons                 text[] := ARRAY[]::text[];
  v_aa_year_band            text;
  v_aa_pto_days_per_year    integer;
BEGIN
  SELECT first_name, last_name, role, role_level, hire_date, category, archived_at, agency_id
    INTO v_team FROM public.team WHERE id = p_requester_team_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('overall_eligibility','ineligible','reasons',ARRAY['team member not found']);
  END IF;
  IF v_team.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object('overall_eligibility','ineligible','reasons',ARRAY['team member is archived']);
  END IF;

  v_weeks_employed := CASE WHEN v_team.hire_date IS NULL THEN 0
                      ELSE FLOOR((CURRENT_DATE - v_team.hire_date) / 7.0)::integer END;
  v_is_post_probation := v_weeks_employed >= 13;

  v_role_level           := COALESCE(v_team.role_level, '');
  v_is_owner             := v_role_level = 'Owner';
  v_is_account_associate := v_role_level = 'Account Associate';
  v_is_manager_tier      := v_role_level IN ('Account Manager', 'Unit Manager', 'Section Manager', 'Office Manager');

  IF v_is_owner THEN
    v_overall := 'eligible';

  ELSIF v_is_manager_tier AND v_is_post_probation THEN
    v_individual_avg := public.team_member_sales_points_avg_13wk(p_requester_team_id);
    v_agency_avg     := public.agency_sales_points_avg_13wk(v_team.agency_id);
    IF v_individual_avg IS NULL OR v_agency_avg IS NULL THEN
      v_overall := 'pending_review';
      v_reasons := array_append(v_reasons,
        'Insufficient weekly Sales Points data for rating — manual review by agent required');
    ELSE
      v_individual_rating := public.compute_sales_points_rating(v_team.agency_id, v_individual_avg);
      v_agency_rating     := public.compute_sales_points_rating(v_team.agency_id, v_agency_avg);
      v_individual_passes := v_individual_rating IN ('Good', 'Great', 'Elite');
      v_agency_passes     := v_agency_rating     IN ('Good', 'Great', 'Elite');
      IF v_individual_passes AND v_agency_passes THEN
        v_overall := 'eligible';
      ELSE
        v_overall := 'ineligible';
        IF NOT v_individual_passes THEN
          v_reasons := array_append(v_reasons,
            format('Individual Sales Points 13-wk avg is %s ($%s/wk) — Good ($1000+) or better required',
                   v_individual_rating, ROUND(v_individual_avg, 0)));
        END IF;
        IF NOT v_agency_passes THEN
          v_reasons := array_append(v_reasons,
            format('Agency Sales Points 13-wk avg is %s ($%s/wk) — Good ($1000+) or better required',
                   v_agency_rating, ROUND(v_agency_avg, 0)));
        END IF;
      END IF;
    END IF;

  ELSIF v_is_manager_tier AND NOT v_is_post_probation THEN
    v_overall := 'pending_review';
    v_reasons := array_append(v_reasons,
      format('%s in 13-week probation (%s of 13 weeks) — case-by-case approval required',
             v_role_level, v_weeks_employed));

  ELSIF v_is_account_associate THEN
    -- Per handbook (02 Hours & Time Off): 0 PTO in year 1, 5 days after year 1, 10 days after year 2.
    IF v_weeks_employed < 52 THEN
      v_aa_year_band := 'year_1';
      v_aa_pto_days_per_year := 0;
      v_overall := 'ineligible';
      v_reasons := array_append(v_reasons,
        format('Account Associate in first year (week %s of 52) — no PTO accrued yet per handbook',
               v_weeks_employed));
    ELSIF v_weeks_employed < 104 THEN
      v_aa_year_band := 'year_2';
      v_aa_pto_days_per_year := 5;
      v_overall := 'pending_review';
      v_reasons := array_append(v_reasons,
        format('Account Associate in year 2 (week %s of 104) — entitled to 5 PTO days/year per handbook; balance check not yet implemented, manual review required',
               v_weeks_employed));
    ELSE
      v_aa_year_band := 'year_3_plus';
      v_aa_pto_days_per_year := 10;
      v_overall := 'pending_review';
      v_reasons := array_append(v_reasons,
        format('Account Associate in year 3+ (week %s) — entitled to 10 PTO days/year per handbook; balance check not yet implemented, manual review required',
               v_weeks_employed));
    END IF;

  ELSE
    v_overall := 'pending_review';
    v_reasons := array_append(v_reasons,
      format('Role level "%s" not mapped to PTO eligibility — manual review required',
             COALESCE(v_team.role_level, 'unknown')));
  END IF;

  RETURN jsonb_build_object(
    'overall_eligibility',         v_overall,
    'is_owner',                    v_is_owner,
    'is_account_manager',          v_role_level = 'Account Manager',
    'is_manager_tier',             v_is_manager_tier,
    'is_account_associate',        v_is_account_associate,
    'is_post_probation',           v_is_post_probation,
    'weeks_employed',              v_weeks_employed,
    'role_level',                  v_team.role_level,
    'individual_avg_sales_points', v_individual_avg,
    'individual_rating',           v_individual_rating,
    'agency_avg_sales_points',     v_agency_avg,
    'agency_rating',               v_agency_rating,
    'aa_year_band',                v_aa_year_band,
    'aa_pto_days_per_year',        v_aa_pto_days_per_year,
    'reasons',                     v_reasons,
    'team_name',                   v_team.first_name || ' ' || v_team.last_name
  );
END;
$function$;
