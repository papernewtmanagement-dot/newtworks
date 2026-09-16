-- Finishing the calendar side: an appointment that moves moves on the calendar,
-- and one that is deleted comes off it.
-- calendar_event_request now builds the update request as well as the create
-- one, so the argument shape still lives in exactly one place. Google's update
-- is a full replacement — anything left out is wiped — so the whole desired
-- state goes every time.

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
  p_exclude_organizer boolean DEFAULT true,
  p_event_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_api_key text; v_user_id text; v_account_id text;
  v_attendees jsonb := '[]'::jsonb; v_email text;
  v_secs bigint; v_hours int; v_mins int; v_args jsonb; v_slug text;
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
    'create_meeting_room',    p_create_meet
  );
  IF NULLIF(btrim(COALESCE(p_location,'')),'') IS NOT NULL THEN
    v_args := v_args || jsonb_build_object('location', btrim(p_location));
  END IF;

  IF NULLIF(btrim(COALESCE(p_event_id,'')),'') IS NULL THEN
    v_slug := 'GOOGLECALENDAR_CREATE_EVENT';
    -- create takes a plain yes/no here; update takes a word.
    v_args := v_args || jsonb_build_object('exclude_organizer', p_exclude_organizer,
                                           'send_updates', p_send_updates);
  ELSE
    v_slug := 'GOOGLECALENDAR_UPDATE_EVENT';
    v_args := v_args || jsonb_build_object('event_id', btrim(p_event_id),
                                           'send_updates', CASE WHEN p_send_updates THEN 'all' ELSE 'none' END);
  END IF;

  RETURN jsonb_build_object(
    'url', 'https://backend.composio.dev/api/v3/tools/execute/' || v_slug,
    'headers', jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
    'body', jsonb_build_object('user_id', v_user_id, 'connected_account_id', v_account_id, 'arguments', v_args)
  );
END $function$;

-- One sender for the requests that have to be waited on. Create or update is
-- decided by whether an event id was passed. Never raises.
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
  p_send_updates boolean DEFAULT true,
  p_event_id text DEFAULT NULL
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
          p_send_updates, false, p_event_id);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

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
  RETURN jsonb_build_object('ok', true, 'event_id', ev->>'id', 'html_link', ev->>'htmlLink',
    'meet_url', COALESCE(ev->>'hangoutLink', ev #>> '{conferenceData,entryPoints,0,uri}'));
END $function$;

-- Taking an event off the calendar. Google treats a missing event as done,
-- so a second delete is harmless.
CREATE OR REPLACE FUNCTION public.calendar_delete_event_now(
  p_agency_id uuid, p_calendar_id text, p_event_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_api_key text; v_user_id text; v_account_id text; resp extensions.http_response;
BEGIN
  IF NULLIF(btrim(COALESCE(p_event_id,'')),'') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'nothing on the calendar');
  END IF;
  SELECT setting_value INTO v_api_key    FROM public.settings WHERE agency_id=p_agency_id AND setting_key='composio_api_key';
  SELECT setting_value INTO v_user_id    FROM public.settings WHERE agency_id=p_agency_id AND setting_key='composio_user_id';
  SELECT setting_value INTO v_account_id FROM public.settings WHERE agency_id=p_agency_id AND setting_key='composio_googlecalendar_account_id';
  IF v_api_key IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'calendar is not set up'); END IF;

  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
  BEGIN
    SELECT * INTO resp FROM extensions.http((
      'POST', 'https://backend.composio.dev/api/v3/tools/execute/GOOGLECALENDAR_DELETE_EVENT',
      ARRAY[extensions.http_header('x-api-key', v_api_key)],
      'application/json',
      jsonb_build_object('user_id', v_user_id, 'connected_account_id', v_account_id,
        'arguments', jsonb_build_object('calendar_id', p_calendar_id,
          'event_id', btrim(p_event_id), 'send_updates', 'all'))::text
    )::extensions.http_request);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'could not reach the calendar: ' || SQLERRM);
  END;
  IF resp.status < 200 OR resp.status >= 300 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'calendar returned ' || resp.status);
  END IF;
  RETURN jsonb_build_object('ok', true);
END $function$;

-- ---------------------------------------------------------------------
-- One place that decides what an appointment looks like on the calendar.
-- Called after the row is written, whether it was just set or just changed.
-- Creates the event the first time and updates it after that, and writes the
-- outcome back onto the row. Never raises: the appointment is the record.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_appointment_sync_calendar(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_host uuid; v_prod text; v_emails text[]; v_cal jsonb;
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

  v_cal := public.calendar_create_event_now(
    r.agency_id, 'primary',
    'Appointment — ' || r.customer_label || ' (' || v_prod || ')',
    'Set in Newtworks.' || E'\n' ||
      'Customer: ' || r.customer_label || COALESCE(' ·' || r.phone_last4, '') || E'\n' ||
      'About: ' || v_prod || E'\n' ||
      'Where: ' || COALESCE(r.location, 'the office') ||
      COALESCE(E'\n\n' || r.note, ''),
    r.starts_at, r.starts_at + make_interval(mins => COALESCE(r.duration_minutes, 30)),
    v_emails, r.location, COALESCE(r.is_video, false), true, r.calendar_event_id);

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

-- Setting an appointment: write the row, then let the one sync function put it
-- on the calendar. The description is not built here any more.
CREATE OR REPLACE FUNCTION public.rp_log_appointment(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_on date := COALESCE(NULLIF(p->>'set_on','')::date, public.rp_today_central());
  v_to uuid := NULLIF(p->>'escalated_to_team_member_id','')::uuid;
  v_first text := btrim(COALESCE(p->>'customer_first',''));
  v_init  text := upper(btrim(COALESCE(p->>'customer_last_initial','')));
  v_lob  text := lower(btrim(COALESCE(p->>'line_of_business','')));
  v_type text := NULLIF(btrim(COALESCE(p->>'product_type','')),'');
  v_starts timestamptz := NULLIF(p->>'starts_at','')::timestamptz;
  v_mins int := GREATEST(15, LEAST(240, COALESCE(NULLIF(p->>'duration_minutes','')::int, 30)));
  v_video boolean := COALESCE((p->>'is_video')::boolean, false);
  v_label text; v_where text; v_cal jsonb; v_id uuid;
  OFFICE constant text := '28120 US Hwy 281 N, Suite 125, San Antonio, TX 78260';
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF v_first = '' THEN RAISE EXCEPTION 'who is the appointment with'; END IF;
  IF regexp_replace(COALESCE(p->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN
    RAISE EXCEPTION 'what product is the appointment about?';
  END IF;
  PERFORM public.rp_check_product_type(a.agency_id, v_lob, v_type);
  IF v_starts IS NULL THEN RAISE EXCEPTION 'when is the appointment?'; END IF;

  v_label := public.rp_customer_label(v_first, v_init);
  v_where := CASE WHEN v_video THEN 'Google Meet' ELSE OFFICE END;

  INSERT INTO public.appointment_log (agency_id, team_member_id, escalated_to_team_member_id,
    customer_first_name, customer_last_initial, customer_label, phone_last4,
    line_of_business, product_type, starts_at, duration_minutes, is_video, location,
    set_on, week_end_date, note, ecrm_url, created_by)
  VALUES (a.agency_id, a.team_member_id, v_to, v_first, v_init, v_label,
    regexp_replace(p->>'phone_last4','\D','','g'), v_lob, v_type,
    v_starts, v_mins, v_video, v_where,
    v_on, public.rp_week_end(v_on),
    NULLIF(btrim(COALESCE(p->>'note','')),''), NULLIF(btrim(COALESCE(p->>'ecrm_url','')),''),
    auth.uid())
  RETURNING id INTO v_id;

  v_cal := public.rp_appointment_sync_calendar(v_id);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'customer', v_label) || v_cal;
END $function$;

-- Editing an appointment: the time, the length and where it is can all change,
-- and the calendar event moves with them.
CREATE OR REPLACE FUNCTION public.rp_edit_appointment(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb); v_on date;
        v_lob text; v_type text; v_starts timestamptz; v_mins int; v_video boolean;
        v_where text; v_cal jsonb;
        OFFICE constant text := '28120 US Hwy 281 N, Suite 125, San Antonio, TX 78260';
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that appointment was removed. Log it again instead.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  v_on := COALESCE(NULLIF(c->>'set_on','')::date, r.set_on);
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  v_lob  := CASE WHEN c ? 'line_of_business' THEN lower(btrim(COALESCE(c->>'line_of_business',''))) ELSE r.line_of_business END;
  v_type := CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'')
                 WHEN c ? 'line_of_business' THEN NULL ELSE r.product_type END;
  IF c ? 'line_of_business' OR c ? 'product_type' THEN
    IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN
      RAISE EXCEPTION 'what product is the appointment about?';
    END IF;
    PERFORM public.rp_check_product_type(r.agency_id, v_lob, v_type);
  END IF;
  v_starts := CASE WHEN c ? 'starts_at' THEN NULLIF(c->>'starts_at','')::timestamptz ELSE r.starts_at END;
  IF c ? 'starts_at' AND v_starts IS NULL THEN RAISE EXCEPTION 'when is the appointment?'; END IF;
  v_mins  := CASE WHEN c ? 'duration_minutes'
                  THEN GREATEST(15, LEAST(240, COALESCE(NULLIF(c->>'duration_minutes','')::int, 30)))
                  ELSE COALESCE(r.duration_minutes, 30) END;
  v_video := CASE WHEN c ? 'is_video' THEN COALESCE((c->>'is_video')::boolean, false) ELSE COALESCE(r.is_video, false) END;
  v_where := CASE WHEN v_video THEN 'Google Meet' ELSE OFFICE END;

  UPDATE public.appointment_log SET
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN c ? 'customer_last_initial' THEN upper(btrim(c->>'customer_last_initial')) ELSE customer_last_initial END,
    customer_label        = CASE WHEN c ? 'customer_first' OR c ? 'customer_last_initial'
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', customer_last_initial))
                                 ELSE customer_label END,
    phone_last4 = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    escalated_to_team_member_id = CASE WHEN c ? 'escalated_to_team_member_id'
                                       THEN NULLIF(c->>'escalated_to_team_member_id','')::uuid
                                       ELSE escalated_to_team_member_id END,
    line_of_business = v_lob,
    product_type     = v_type,
    starts_at        = v_starts,
    duration_minutes = v_mins,
    is_video         = v_video,
    location         = v_where,
    set_on = v_on,
    week_end_date = public.rp_week_end(v_on),
    note     = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    ecrm_url = CASE WHEN c ? 'ecrm_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_url','')),'') ELSE ecrm_url END,
    updated_at = now()
  WHERE id = p_id;

  v_cal := public.rp_appointment_sync_calendar(p_id);
  RETURN jsonb_build_object('ok', true, 'id', p_id) || v_cal;
END $function$;

-- Deleting an appointment takes its event off the calendar. If the calendar
-- cannot be reached the appointment still goes: the reason is reported so it
-- can be cleared by hand.
CREATE OR REPLACE FUNCTION public.rp_void_appointment(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; v_del jsonb := '{}'::jsonb;
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  IF r.calendar_event_id IS NOT NULL THEN
    v_del := public.calendar_delete_event_now(r.agency_id, 'primary', r.calendar_event_id);
  END IF;

  UPDATE public.appointment_log
     SET status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason,
         calendar_event_id = CASE WHEN COALESCE((v_del->>'ok')::boolean, true) THEN NULL ELSE calendar_event_id END,
         calendar_error = CASE WHEN COALESCE((v_del->>'ok')::boolean, true) THEN NULL
                               ELSE 'still on the calendar: ' || COALESCE(v_del->>'error','') END,
         updated_at = now()
   WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'id', p_id,
    'off_calendar', CASE WHEN r.calendar_event_id IS NULL THEN NULL ELSE COALESCE((v_del->>'ok')::boolean, false) END,
    'calendar_error', CASE WHEN COALESCE((v_del->>'ok')::boolean, true) THEN NULL ELSE v_del->>'error' END);
END $function$;
