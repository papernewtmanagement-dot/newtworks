-- One place that knows how to ask Google for a calendar event.
-- Two callers need different transport, not different arguments:
--   time_off_calendar_dispatch fires a batch and never waits, then reads the
--     event ids back out of net._http_response hours later.
--   a person booking an appointment in the browser needs the event id now.
-- So the REQUEST is built once here and the two callers only differ in how
-- they send it. Do not build a second copy of these arguments.

CREATE OR REPLACE FUNCTION public.calendar_event_request(
  p_agency_id uuid,
  p_calendar_id text,
  p_summary text,
  p_description text,
  p_start_datetime timestamptz,
  p_end_datetime timestamptz,
  p_attendee_emails text[] DEFAULT NULL,
  p_location text DEFAULT NULL,
  p_create_meet boolean DEFAULT false,
  p_send_updates boolean DEFAULT false,
  p_exclude_organizer boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_api_key text; v_user_id text; v_account_id text;
  v_attendees jsonb := '[]'::jsonb; v_email text;
  v_secs bigint; v_hours int; v_mins int; v_args jsonb;
BEGIN
  SELECT setting_value INTO v_api_key   FROM public.settings WHERE agency_id=p_agency_id AND setting_key='composio_api_key';
  SELECT setting_value INTO v_user_id   FROM public.settings WHERE agency_id=p_agency_id AND setting_key='composio_user_id';
  SELECT setting_value INTO v_account_id FROM public.settings WHERE agency_id=p_agency_id AND setting_key='composio_googlecalendar_account_id';
  IF v_api_key IS NULL OR v_user_id IS NULL OR v_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Google Calendar config missing in settings';
  END IF;

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

  RETURN jsonb_build_object(
    'url', 'https://backend.composio.dev/api/v3/tools/execute/GOOGLECALENDAR_CREATE_EVENT',
    'headers', jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
    'body', jsonb_build_object('user_id', v_user_id, 'connected_account_id', v_account_id, 'arguments', v_args)
  );
END $function$;

COMMENT ON FUNCTION public.calendar_event_request IS
  'Builds the Composio GOOGLECALENDAR_CREATE_EVENT request. The only place the calendar argument shape lives. Send it with net.http_post to fire and forget, or with calendar_create_event_now to wait for the event id.';

-- Fire and forget, unchanged behaviour: same signature, same return, now built
-- from the shared request instead of its own copy of the arguments.
CREATE OR REPLACE FUNCTION public.time_off_create_calendar_event(
  p_agency_id uuid, p_calendar_id text, p_summary text, p_description text,
  p_start_datetime timestamptz, p_end_datetime timestamptz, p_attendee_emails text[]
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $function$
DECLARE r jsonb; v_id bigint;
BEGIN
  r := public.calendar_event_request(p_agency_id, p_calendar_id, p_summary, p_description,
        p_start_datetime, p_end_datetime, p_attendee_emails, NULL, false, false, true);
  SELECT net.http_post(url := r->>'url', headers := r->'headers', body := r->'body') INTO v_id;
  RETURN v_id;
END $function$;

-- Wait for the answer. One event, booked by a person who is looking at the
-- screen, so the event id and any Meet link come back in the same call.
-- Never raises: the caller decides what a calendar failure means to it.
CREATE OR REPLACE FUNCTION public.calendar_create_event_now(
  p_agency_id uuid,
  p_calendar_id text,
  p_summary text,
  p_description text,
  p_start_datetime timestamptz,
  p_end_datetime timestamptz,
  p_attendee_emails text[] DEFAULT NULL,
  p_location text DEFAULT NULL,
  p_create_meet boolean DEFAULT false,
  p_send_updates boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r jsonb; resp extensions.http_response; c jsonb; ev jsonb;
BEGIN
  BEGIN
    r := public.calendar_event_request(p_agency_id, p_calendar_id, p_summary, p_description,
          p_start_datetime, p_end_datetime, p_attendee_emails, p_location, p_create_meet,
          p_send_updates, false);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  -- Eight seconds. A person is waiting on this, and the appointment itself is
  -- already safe whether or not Google answers.
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
  BEGIN
    SELECT * INTO resp FROM extensions.http((
      'POST', r->>'url',
      ARRAY[extensions.http_header('x-api-key', r->'headers'->>'x-api-key')],
      'application/json', (r->'body')::text
    )::extensions.http_request);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'could not reach the calendar: ' || SQLERRM);
  END;

  IF resp.status < 200 OR resp.status >= 300 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'calendar returned ' || resp.status);
  END IF;

  BEGIN c := resp.content::jsonb; EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'calendar sent back something unreadable');
  END;
  ev := c #> '{data,response_data}';
  IF ev IS NULL OR ev->>'id' IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', COALESCE(c->>'error', 'the calendar did not return an event'));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'event_id', ev->>'id',
    'html_link', ev->>'htmlLink',
    'meet_url', COALESCE(ev->>'hangoutLink',
                         ev #>> '{conferenceData,entryPoints,0,uri}')
  );
END $function$;
