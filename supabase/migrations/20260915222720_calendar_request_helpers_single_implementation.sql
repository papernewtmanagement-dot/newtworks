-- Same behaviour, but the settings lookup and the URL/header shape now live in
-- composio_tool_request only. One implementation, every caller moves together.
CREATE OR REPLACE FUNCTION public.calendar_event_request(
  p_agency_id uuid, p_calendar_id text, p_summary text, p_description text,
  p_start_datetime timestamptz, p_end_datetime timestamptz,
  p_attendee_emails text[] DEFAULT NULL::text[], p_location text DEFAULT NULL::text,
  p_create_meet boolean DEFAULT false, p_send_updates boolean DEFAULT false,
  p_exclude_organizer boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
  v_attendees jsonb := '[]'::jsonb; v_email text;
  v_secs bigint; v_hours int; v_mins int; v_args jsonb;
BEGIN
  IF p_attendee_emails IS NOT NULL THEN
    FOREACH v_email IN ARRAY p_attendee_emails LOOP
      IF v_email IS NOT NULL AND btrim(v_email) <> '' THEN
        v_attendees := v_attendees || to_jsonb(btrim(v_email));
      END IF;
    END LOOP;
  END IF;

  v_secs  := EXTRACT(EPOCH FROM (p_end_datetime - p_start_datetime))::bigint;
  v_hours := (v_secs / 3600)::int;
  v_mins  := ((v_secs % 3600) / 60)::int;
  IF v_mins > 59 THEN v_mins := 59; END IF;
  IF v_hours = 0 AND v_mins = 0 THEN v_mins := 30; END IF;

  v_args := jsonb_build_object(
    'calendar_id',            p_calendar_id,
    'summary',                p_summary,
    'description',            p_description,
    'start_datetime',         to_char(p_start_datetime AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'timezone',               'America/Chicago',
    'event_duration_hour',    v_hours,
    'event_duration_minutes', v_mins,
    'attendees',              v_attendees,
    'create_meeting_room',    p_create_meet,
    'exclude_organizer',      p_exclude_organizer,
    'send_updates',           p_send_updates
  );
  IF NULLIF(btrim(COALESCE(p_location,'')),'') IS NOT NULL THEN
    v_args := v_args || jsonb_build_object('location', btrim(p_location));
  END IF;

  RETURN public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_CREATE_EVENT', v_args);
END $fn$;

-- Posting now happens in composio_post only.
CREATE OR REPLACE FUNCTION public.time_off_create_calendar_event(
  p_agency_id uuid, p_calendar_id text, p_summary text, p_description text,
  p_start_datetime timestamptz, p_end_datetime timestamptz, p_attendee_emails text[]
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','net'
AS $fn$
BEGIN
  RETURN public.composio_post(
    public.calendar_event_request(p_agency_id, p_calendar_id, p_summary, p_description,
      p_start_datetime, p_end_datetime, p_attendee_emails, NULL, false, false, true));
END $fn$;
