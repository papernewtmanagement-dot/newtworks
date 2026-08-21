-- Composio schema docs say send_updates is an enum string, but the runtime validator
-- rejects strings with "Input should be a valid boolean". Empirically false (boolean)
-- is accepted. Reverting that one parameter — keeping all other fixes intact
-- (duration math, exclude_organizer, event_id capture second pass).
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
        'send_updates',           false
      )
    )
  ) INTO v_pg_net_id;

  RETURN v_pg_net_id;
END;
$function$;
