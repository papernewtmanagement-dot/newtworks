-- One place that turns a Composio tool call into an HTTP request, and one place that posts it.
-- calendar_event_request already built its own copy of the settings lookup; it now calls this,
-- so there is a single implementation and every caller moves together.
CREATE OR REPLACE FUNCTION public.composio_tool_request(
  p_agency_id uuid, p_tool_slug text, p_arguments jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_api_key text; v_user_id text; v_account_id text;
BEGIN
  SELECT setting_value INTO v_api_key    FROM public.settings WHERE agency_id=p_agency_id AND setting_key='composio_api_key';
  SELECT setting_value INTO v_user_id    FROM public.settings WHERE agency_id=p_agency_id AND setting_key='composio_user_id';
  SELECT setting_value INTO v_account_id FROM public.settings WHERE agency_id=p_agency_id AND setting_key='composio_googlecalendar_account_id';
  IF v_api_key IS NULL OR v_user_id IS NULL OR v_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Google Calendar config missing in settings';
  END IF;
  RETURN jsonb_build_object(
    'url', 'https://backend.composio.dev/api/v3/tools/execute/' || p_tool_slug,
    'headers', jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
    'body', jsonb_build_object('user_id', v_user_id, 'connected_account_id', v_account_id, 'arguments', p_arguments)
  );
END $fn$;

CREATE OR REPLACE FUNCTION public.composio_post(p_request jsonb)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','net'
AS $fn$
DECLARE v_id bigint;
BEGIN
  SELECT net.http_post(url := p_request->>'url', headers := p_request->'headers', body := p_request->'body') INTO v_id;
  RETURN v_id;
END $fn$;

-- Edit an existing event in place. Never delete and recreate.
CREATE OR REPLACE FUNCTION public.calendar_event_patch_request(
  p_agency_id uuid, p_calendar_id text, p_event_id text,
  p_start_datetime timestamptz, p_end_datetime timestamptz,
  p_summary text DEFAULT NULL, p_description text DEFAULT NULL,
  p_send_updates text DEFAULT 'all'
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_args jsonb;
BEGIN
  v_args := jsonb_build_object(
    'calendar_id',  p_calendar_id,
    'event_id',     p_event_id,
    'start_time',   to_char(p_start_datetime AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'end_time',     to_char(p_end_datetime   AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'timezone',     'America/Chicago',
    'send_updates', p_send_updates
  );
  IF p_summary     IS NOT NULL THEN v_args := v_args || jsonb_build_object('summary', p_summary); END IF;
  IF p_description IS NOT NULL THEN v_args := v_args || jsonb_build_object('description', p_description); END IF;
  RETURN public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_PATCH_EVENT', v_args);
END $fn$;

CREATE OR REPLACE FUNCTION public.calendar_event_delete_request(
  p_agency_id uuid, p_calendar_id text, p_event_id text, p_send_updates text DEFAULT 'all'
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
BEGIN
  RETURN public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_DELETE_EVENT',
    jsonb_build_object('calendar_id', p_calendar_id, 'event_id', p_event_id, 'send_updates', p_send_updates));
END $fn$;
