-- Two sessions built calendar plumbing on 2026-09-15 within minutes of each
-- other. This merges them into one stack rather than leaving two:
--   composio_tool_request(agency, slug, args)  -> the request      (kept)
--   composio_post(request)                     -> fire and forget  (kept)
--   composio_post_now(request)                 -> wait for the answer (new)
--   calendar_event_request / _patch_request / _delete_request -> the arguments
--   calendar_create_event_now / _patch_ / _delete_ -> send and read the answer
-- calendar_event_request no longer looks up its own credentials and no longer
-- knows how to update: changing an event goes through the patch request, which
-- only touches the fields it is given. Google's full update wipes anything left
-- out, which is why patch wins.

-- One synchronous sender, matching composio_post.
CREATE OR REPLACE FUNCTION public.composio_post_now(p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE resp extensions.http_response; c jsonb;
BEGIN
  -- Eight seconds. Someone is usually waiting on this one.
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
  BEGIN
    SELECT * INTO resp FROM extensions.http((
      'POST', p_request->>'url',
      ARRAY[extensions.http_header('x-api-key', p_request->'headers'->>'x-api-key')],
      'application/json', (p_request->'body')::text
    )::extensions.http_request);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'could not reach it: ' || SQLERRM);
  END;
  IF resp.status < 200 OR resp.status >= 300 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'got back ' || resp.status);
  END IF;
  BEGIN c := resp.content::jsonb; EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'the answer could not be read');
  END;
  IF COALESCE((c->>'successful')::boolean, true) = false THEN
    RETURN jsonb_build_object('ok', false, 'error', COALESCE(c->>'error', 'it refused'));
  END IF;
  RETURN jsonb_build_object('ok', true, 'data', c #> '{data,response_data}');
END $function$;

-- Creating an event: arguments only, credentials come from composio_tool_request.
DROP FUNCTION IF EXISTS public.calendar_event_request(uuid,text,text,text,timestamptz,timestamptz,text[],text,boolean,boolean,boolean,text);
CREATE FUNCTION public.calendar_event_request(
  p_agency_id uuid, p_calendar_id text, p_summary text, p_description text,
  p_start_datetime timestamptz, p_end_datetime timestamptz,
  p_attendee_emails text[] DEFAULT NULL, p_location text DEFAULT NULL,
  p_create_meet boolean DEFAULT false, p_send_updates boolean DEFAULT false,
  p_exclude_organizer boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_attendees jsonb := '[]'::jsonb; v_email text;
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
    'send_updates',           p_send_updates);
  IF NULLIF(btrim(COALESCE(p_location,'')),'') IS NOT NULL THEN
    v_args := v_args || jsonb_build_object('location', btrim(p_location));
  END IF;
  RETURN public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_CREATE_EVENT', v_args);
END $function$;

-- Patching an event: same shape as before plus where it is and who is on it.
-- The existing task caller passes the first eight arguments and is unaffected.
DROP FUNCTION IF EXISTS public.calendar_event_patch_request(uuid,text,text,timestamptz,timestamptz,text,text,text);
CREATE FUNCTION public.calendar_event_patch_request(
  p_agency_id uuid, p_calendar_id text, p_event_id text,
  p_start_datetime timestamptz, p_end_datetime timestamptz,
  p_summary text DEFAULT NULL, p_description text DEFAULT NULL,
  p_send_updates text DEFAULT 'all',
  p_location text DEFAULT NULL, p_attendee_emails text[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_args jsonb; v_attendees jsonb := '[]'::jsonb; v_email text;
BEGIN
  v_args := jsonb_build_object(
    'calendar_id',  p_calendar_id,
    'event_id',     p_event_id,
    'start_time',   to_char(p_start_datetime AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'end_time',     to_char(p_end_datetime   AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'timezone',     'America/Chicago',
    'send_updates', p_send_updates);
  IF p_summary     IS NOT NULL THEN v_args := v_args || jsonb_build_object('summary', p_summary); END IF;
  IF p_description IS NOT NULL THEN v_args := v_args || jsonb_build_object('description', p_description); END IF;
  IF NULLIF(btrim(COALESCE(p_location,'')),'') IS NOT NULL THEN
    v_args := v_args || jsonb_build_object('location', btrim(p_location));
  END IF;
  -- Attendees are replaced wholesale when given, so only send them when asked.
  IF p_attendee_emails IS NOT NULL THEN
    FOREACH v_email IN ARRAY p_attendee_emails LOOP
      IF v_email IS NOT NULL AND btrim(v_email) <> '' THEN
        v_attendees := v_attendees || to_jsonb(btrim(v_email));
      END IF;
    END LOOP;
    v_args := v_args || jsonb_build_object('attendees', v_attendees);
  END IF;
  RETURN public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_PATCH_EVENT', v_args);
END $function$;

-- The three waiting senders. All of them return {ok, ...} and never raise.
CREATE OR REPLACE FUNCTION public.calendar_create_event_now(
  p_agency_id uuid, p_calendar_id text, p_summary text, p_description text,
  p_start_datetime timestamptz, p_end_datetime timestamptz,
  p_attendee_emails text[] DEFAULT NULL, p_location text DEFAULT NULL,
  p_create_meet boolean DEFAULT false, p_send_updates boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r jsonb; res jsonb; ev jsonb;
BEGIN
  BEGIN
    r := public.calendar_event_request(p_agency_id, p_calendar_id, p_summary, p_description,
          p_start_datetime, p_end_datetime, p_attendee_emails, p_location, p_create_meet,
          p_send_updates, false);
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('ok', false, 'error', SQLERRM); END;
  res := public.composio_post_now(r);
  IF NOT COALESCE((res->>'ok')::boolean, false) THEN RETURN res; END IF;
  ev := res->'data';
  IF ev IS NULL OR ev->>'id' IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'the calendar did not return an event');
  END IF;
  RETURN jsonb_build_object('ok', true, 'event_id', ev->>'id', 'html_link', ev->>'htmlLink',
    'meet_url', COALESCE(ev->>'hangoutLink', ev #>> '{conferenceData,entryPoints,0,uri}'));
END $function$;

CREATE OR REPLACE FUNCTION public.calendar_patch_event_now(
  p_agency_id uuid, p_calendar_id text, p_event_id text,
  p_start_datetime timestamptz, p_end_datetime timestamptz,
  p_summary text DEFAULT NULL, p_description text DEFAULT NULL,
  p_location text DEFAULT NULL, p_attendee_emails text[] DEFAULT NULL,
  p_send_updates text DEFAULT 'all'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r jsonb; res jsonb; ev jsonb;
BEGIN
  BEGIN
    r := public.calendar_event_patch_request(p_agency_id, p_calendar_id, p_event_id,
          p_start_datetime, p_end_datetime, p_summary, p_description, p_send_updates,
          p_location, p_attendee_emails);
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('ok', false, 'error', SQLERRM); END;
  res := public.composio_post_now(r);
  IF NOT COALESCE((res->>'ok')::boolean, false) THEN RETURN res; END IF;
  ev := res->'data';
  RETURN jsonb_build_object('ok', true, 'event_id', COALESCE(ev->>'id', p_event_id),
    'meet_url', COALESCE(ev->>'hangoutLink', ev #>> '{conferenceData,entryPoints,0,uri}'));
END $function$;

CREATE OR REPLACE FUNCTION public.calendar_delete_event_now(
  p_agency_id uuid, p_calendar_id text, p_event_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r jsonb;
BEGIN
  IF NULLIF(btrim(COALESCE(p_event_id,'')),'') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'nothing on the calendar');
  END IF;
  BEGIN
    r := public.calendar_event_delete_request(p_agency_id, p_calendar_id, btrim(p_event_id), 'all');
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('ok', false, 'error', SQLERRM); END;
  RETURN public.composio_post_now(r);
END $function$;

-- The appointment sync now creates the first time and patches after that.
CREATE OR REPLACE FUNCTION public.rp_appointment_sync_calendar(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_host uuid; v_prod text; v_emails text[]; v_cal jsonb;
        v_summary text; v_desc text; v_end timestamptz;
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not found'); END IF;
  IF r.starts_at IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no time on the appointment'); END IF;

  v_host := COALESCE(NULLIF(r.escalated_to_team_member_id, r.team_member_id), r.team_member_id);
  SELECT pt.label INTO v_prod FROM public.product_types pt
   WHERE pt.agency_id = r.agency_id AND pt.line_of_business = r.line_of_business
     AND pt.type_key = r.product_type AND pt.is_active;
  v_prod := COALESCE(v_prod, initcap(COALESCE(r.line_of_business, 'appointment')));

  -- Whoever is running it, plus whoever set it. The customer is never invited:
  -- we hold a first name, a last initial and four phone digits, never an email.
  SELECT array_agg(e) INTO v_emails FROM (
    SELECT DISTINCT COALESCE(t.email_sf, t.email_personal) AS e
    FROM public.team t
    WHERE t.id IN (v_host, r.team_member_id) AND COALESCE(t.email_sf, t.email_personal) IS NOT NULL
  ) s;

  v_summary := 'Appointment — ' || r.customer_label || ' (' || v_prod || ')';
  v_desc := 'Set in Newtworks.' || E'\n' ||
    'Customer: ' || r.customer_label || COALESCE(' ·' || r.phone_last4, '') || E'\n' ||
    'About: ' || v_prod || E'\n' ||
    'Where: ' || COALESCE(r.location, 'the office') ||
    COALESCE(E'\n\n' || r.note, '');
  v_end := r.starts_at + make_interval(mins => COALESCE(r.duration_minutes, 30));

  IF r.calendar_event_id IS NULL THEN
    v_cal := public.calendar_create_event_now(r.agency_id, 'primary', v_summary, v_desc,
      r.starts_at, v_end, v_emails, r.location, COALESCE(r.is_video, false), true);
  ELSE
    v_cal := public.calendar_patch_event_now(r.agency_id, 'primary', r.calendar_event_id,
      r.starts_at, v_end, v_summary, v_desc, r.location, v_emails, 'all');
  END IF;

  UPDATE public.appointment_log SET
    calendar_event_id = COALESCE(v_cal->>'event_id', calendar_event_id),
    meet_url          = COALESCE(v_cal->>'meet_url', meet_url),
    calendar_error    = CASE WHEN COALESCE((v_cal->>'ok')::boolean, false) THEN NULL ELSE v_cal->>'error' END
  WHERE id = p_id;

  RETURN jsonb_build_object(
    'on_calendar', COALESCE((v_cal->>'ok')::boolean, false),
    'meet_url', v_cal->>'meet_url',
    'calendar_error', CASE WHEN COALESCE((v_cal->>'ok')::boolean, false) THEN NULL ELSE v_cal->>'error' END);
END $function$;
