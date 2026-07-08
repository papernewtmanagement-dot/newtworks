-- Tier-3 DRY (Q2): add 'agency_active_all' purpose to get_expected_teammates,
-- refactor send_weekly_cpr_recap + huddle_calendar_sync to use it.
--
-- New purpose covers: active agency people, non-admin, non-test, non-archived-as-of,
-- Owner INCLUDED. Fills the gap -- all prior agency purposes excluded Owner.
--
-- huddle_calendar_sync 1-arg was DROP+CREATE (prod had DEFAULT '126794dd-...' on
-- p_agency_id that CREATE OR REPLACE cannot reshape). Default preserved.
--
-- Applied via Supabase MCP 2026-07-08. This file is the byte-exact mirror of the
-- production function definitions (extracted from pg_proc via pg_get_functiondef).

-- (1) Canonical: add agency_active_all branch
CREATE OR REPLACE FUNCTION public.get_expected_teammates(
  p_agency_id uuid, p_purpose text, p_as_of_date date DEFAULT NULL::date
) RETURNS TABLE(
  team_id uuid, first_name text, last_name text, nickname text, display_name text,
  category text, role text, role_level text, role_category text,
  email_sf text, email_personal text, start_date date
)
LANGUAGE sql
STABLE
AS $function$
  SELECT
    t.id AS team_id,
    t.first_name,
    t.last_name,
    t.nickname,
    COALESCE(NULLIF(t.nickname, ''), t.first_name) AS display_name,
    t.category,
    t.role,
    t.role_level,
    t.role_category,
    t.email_sf,
    t.email_personal,
    t.start_date
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND t.is_test_user IS NOT TRUE
    AND t.is_admin_backoffice = false
    AND (
      p_as_of_date IS NULL AND t.archived_at IS NULL
      OR p_as_of_date IS NOT NULL AND (t.archived_at IS NULL OR t.archived_at > p_as_of_date::timestamptz)
    )
    AND (
      (p_purpose = 'work_checkin'
        AND (t.include_in_team_checkins = true OR
             (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner'))
        AND COALESCE(t.tag_in_team_reminders, true) = true)
      OR
      (p_purpose = 'health_checkin'
        AND (t.include_in_health_checkins = true OR
             (t.include_in_health_checkins IS NULL AND t.category = 'agency')))
      OR
      (p_purpose = 'compensation'
        AND t.category = 'agency'
        AND COALESCE(t.role_level, '') != 'Owner')
      OR
      (p_purpose = 'time_off_participant'
        AND t.category = 'agency'
        AND COALESCE(t.role_level, '') != 'Owner'
        AND t.is_active = true)
      OR
      (p_purpose = 'wtw_am_sales'
        AND t.role_level IN ('Account Manager', 'Unit Manager')
        AND t.role_category = 'Sales'
        AND (t.include_in_team_checkins = true OR
             (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')))
      OR
      (p_purpose = 'wtw_am_retention'
        AND t.role_level IN ('Account Manager', 'Unit Manager')
        AND t.role_category = 'Retention'
        AND (t.include_in_team_checkins = true OR
             (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')))
      OR
      (p_purpose = 'agency_am_um'
        AND t.category = 'agency'
        AND t.role_level IN ('Account Manager', 'Unit Manager'))
      OR
      (p_purpose = 'agency_active_all'
        AND t.category = 'agency'
        AND t.is_active = true)
    );
$function$;

-- (2) send_weekly_cpr_recap: roster now via canonical
CREATE OR REPLACE FUNCTION public.send_weekly_cpr_recap(p_agency_id uuid, p_week_ending_date date)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_report                  record;
  v_html                    text;
  v_api_key                 text;
  v_user_id                 text;
  v_connected_account_id    text;
  v_subject                 text;
  v_week_start              date := p_week_ending_date - 6;
  v_start_mon               text;
  v_end_mon                 text;
  v_start_day               text;
  v_end_day                 text;
  v_subject_dates           text;
  v_request_id              bigint;
  v_recipients_to           text[];
  v_primary_to              text;
  v_extra_to                text[];
BEGIN
  SELECT * INTO v_report FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'No weekly_cpr_reports row exists for this week.');
  END IF;

  IF v_report.sent_to_team_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Already Gmail-confirmed at ' || v_report.sent_to_team_at::text);
  END IF;

  IF COALESCE(v_report.send_attempt_count, 0) >= 3 THEN
    RETURN jsonb_build_object('success', false,
      'error', format('Attempt cap reached (%s of 3). Manual send required — clear send_attempt_count to reset.',
                      v_report.send_attempt_count));
  END IF;

  IF v_report.send_dispatched_at IS NOT NULL
     AND v_report.send_dispatched_at > now() - INTERVAL '90 minutes' THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Recent dispatch within 90 min at ' || v_report.send_dispatched_at::text ||
               '. verify_pending_cpr_sends is still working on it. Wait or clear send_dispatched_at to force retry.');
  END IF;

  IF v_report.opener_text IS NULL OR btrim(v_report.opener_text) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Opener text is empty.');
  END IF;

  IF v_report.looking_next_week_text IS NULL OR btrim(v_report.looking_next_week_text) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', '"Looking at next week" text is empty.');
  END IF;

  SELECT setting_value INTO v_api_key FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_user_id FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_connected_account_id FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'composio_gmail_account_id';

  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Composio Gmail config missing in settings');
  END IF;

  SELECT array_agg(et.email_sf ORDER BY
                   CASE WHEN et.role_level = 'Owner' THEN 1 ELSE 0 END,
                   t.hire_date ASC NULLS LAST, et.last_name)
    INTO v_recipients_to
  FROM public.get_expected_teammates(p_agency_id, 'agency_active_all', NULL) et
  JOIN public.team t ON t.id = et.team_id
  WHERE et.email_sf IS NOT NULL
    AND btrim(et.email_sf) <> '';

  IF v_recipients_to IS NULL OR array_length(v_recipients_to, 1) IS NULL OR array_length(v_recipients_to, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'No active agency team members with SF emails found in team table');
  END IF;

  v_primary_to := v_recipients_to[1];
  IF array_length(v_recipients_to, 1) > 1 THEN
    v_extra_to := v_recipients_to[2:];
  ELSE
    v_extra_to := ARRAY[]::text[];
  END IF;

  v_start_mon := upper(to_char(v_week_start,       'Mon'));
  v_end_mon   := upper(to_char(p_week_ending_date, 'Mon'));
  v_start_day := to_char(v_week_start,       'FMDD');
  v_end_day   := to_char(p_week_ending_date, 'FMDD');
  IF v_start_mon = v_end_mon THEN
    v_subject_dates := v_start_mon || ' ' || v_start_day || '-' || v_end_day;
  ELSE
    v_subject_dates := v_start_mon || ' ' || v_start_day || ' - ' || v_end_mon || ' ' || v_end_day;
  END IF;

  v_subject := E'\xF0\x9F\x93\x8A CPR RECAP \xE2\x80\x94 WEEK OF ' || v_subject_dates;
  v_html := public.compose_weekly_cpr_html(p_agency_id, p_week_ending_date);

  UPDATE public.weekly_cpr_reports
     SET send_dispatched_at     = now(),
         send_attempt_count     = COALESCE(send_attempt_count, 0) + 1,
         gmail_message_id       = NULL,
         gmail_verify_request_id = NULL,
         send_request_id        = NULL
   WHERE id = v_report.id;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/GMAIL_SEND_EMAIL',
    headers := jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'user_id', v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments', jsonb_build_object(
        'recipient_email', v_primary_to,
        'extra_recipients', to_jsonb(v_extra_to),
        'subject', v_subject,
        'body', v_html,
        'is_html', true
      )
    ),
    timeout_milliseconds := 180000
  ) INTO v_request_id;

  UPDATE public.weekly_cpr_reports SET send_request_id = v_request_id WHERE id = v_report.id;

  RETURN jsonb_build_object(
    'success', true,
    'status', 'pending',
    'request_id', v_request_id,
    'attempt', COALESCE(v_report.send_attempt_count, 0) + 1,
    'subject', v_subject,
    'recipients', v_recipients_to,
    'note', 'Dispatched to Composio. verify_pending_cpr_sends will confirm via Gmail lookup.'
  );
END;
$function$;

-- (3) huddle_calendar_sync 1-arg: DROP + CREATE preserving the DEFAULT
DROP FUNCTION IF EXISTS public.huddle_calendar_sync(uuid);

CREATE FUNCTION public.huddle_calendar_sync(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_api_key text;
  v_user_id text;
  v_connected_account_id text;
  v_pg_net_id bigint;
  v_attendees jsonb;
  v_start_ts text;
  v_action text;
  v_arguments jsonb;
BEGIN
  SELECT * INTO v FROM public.agency_huddle_config
  WHERE agency_id = p_agency_id
    AND calendar_needs_sync = true
    AND calendar_id IS NOT NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','noop','reason','no rows flagged');
  END IF;

  SELECT setting_value INTO v_api_key FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_user_id FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_connected_account_id FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'composio_googlecalendar_account_id';
  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Google Calendar config missing in settings';
  END IF;

  SELECT jsonb_agg(email) INTO v_attendees FROM (
    SELECT et.email_sf AS email
    FROM public.get_expected_teammates(p_agency_id, 'agency_active_all', NULL) et
    WHERE et.email_sf IS NOT NULL AND et.email_sf <> ''
    UNION ALL
    SELECT et.email_personal
    FROM public.get_expected_teammates(p_agency_id, 'agency_active_all', NULL) et
    WHERE et.email_personal IS NOT NULL AND et.email_personal <> ''
  ) e;

  v_start_ts := COALESCE(v.event_first_date, CURRENT_DATE)::text
                || 'T' || TO_CHAR(v.start_time_local, 'HH24:MI:SS');

  IF v.calendar_event_id IS NULL THEN
    v_action := 'GOOGLECALENDAR_CREATE_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',            v.calendar_id,
      'summary',                v.event_title,
      'description',            'Story Agency team huddle. Managed by BCC agency_huddle_config. Rhythm + this week''s leader in BCC → Playbook → Team Huddle → Daily Rhythm.',
      'start_datetime',         v_start_ts,
      'timezone',               'America/Chicago',
      'event_duration_hour',    0,
      'event_duration_minutes', v.duration_regular_min,
      'recurrence',             jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ',')),
      'attendees',              COALESCE(v_attendees, '[]'::jsonb),
      'create_meeting_room',    true,
      'exclude_organizer',      true,
      'send_updates',           'all',
      'guestsCanInviteOthers',  false,
      'guestsCanSeeOtherGuests', true
    );
  ELSE
    v_action := 'GOOGLECALENDAR_UPDATE_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',            v.calendar_id,
      'event_id',               v.calendar_event_id,
      'summary',                v.event_title,
      'start_datetime',         v_start_ts,
      'timezone',               'America/Chicago',
      'event_duration_hour',    0,
      'event_duration_minutes', v.duration_regular_min,
      'recurrence',             jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ',')),
      'attendees',              COALESCE(v_attendees, '[]'::jsonb),
      'send_updates',           'all'
    );
  END IF;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/' || v_action,
    headers := jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'user_id',              v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments',            v_arguments
    )
  ) INTO v_pg_net_id;

  UPDATE public.agency_huddle_config
  SET calendar_needs_sync = false,
      calendar_last_synced_at = NOW()
  WHERE agency_id = p_agency_id;

  RETURN jsonb_build_object(
    'status','dispatched',
    'action', v_action,
    'pg_net_id', v_pg_net_id,
    'start_datetime', v_start_ts
  );
END;
$function$;
