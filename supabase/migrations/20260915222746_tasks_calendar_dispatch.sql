-- Puts "complete at" times on the Story Agency Tasks calendar and invites the task owner.
-- Four passes: create, capture the event id, edit in place when the time moves, remove when cleared.
-- Does nothing at all while settings.gcal_tasks_calendar_id is blank.
CREATE OR REPLACE FUNCTION public.tasks_calendar_dispatch(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','net'
AS $fn$
DECLARE
  v_cal       text;
  v_created   int := 0;
  v_captured  int := 0;
  v_patched   int := 0;
  v_removed   int := 0;
  v_t         RECORD;
  v_req_id    bigint;
  v_event_id  text;
  v_desc      text;
  v_attendees text[];
  v_app_url   text := 'https://newtworks.vercel.app';
  v_len       interval := INTERVAL '30 minutes';
BEGIN
  SELECT NULLIF(btrim(setting_value), '') INTO v_cal
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'gcal_tasks_calendar_id';

  IF v_cal IS NULL THEN
    RETURN jsonb_build_object('skipped', 'no tasks calendar set yet',
                              'events_created', 0, 'event_ids_captured', 0,
                              'events_updated', 0, 'events_removed', 0,
                              'dispatched_at', NOW());
  END IF;

  -- 1. New: a complete_at with no event yet.
  FOR v_t IN
    SELECT t.id, t.title, t.description, t.complete_at, u.email
    FROM public.tasks t
    LEFT JOIN public.users u ON u.id = t.assigned_to
    WHERE t.agency_id = p_agency_id
      AND t.complete_at IS NOT NULL
      AND t.calendar_event_id IS NULL
      AND t.calendar_pg_net_request_id IS NULL
      AND COALESCE(t.status, 'open') <> 'closed'
  LOOP
    v_desc := COALESCE(NULLIF(btrim(COALESCE(v_t.description, '')), '') || E'\n\n', '')
              || 'Task in Newtworks: ' || v_app_url;
    v_attendees := CASE WHEN v_t.email IS NOT NULL AND btrim(v_t.email) <> ''
                        THEN ARRAY[v_t.email] ELSE ARRAY[]::text[] END;

    v_req_id := public.composio_post(
      public.calendar_event_request(
        p_agency_id, v_cal, v_t.title, v_desc,
        v_t.complete_at, v_t.complete_at + v_len,
        v_attendees, NULL, false, true, true));

    UPDATE public.tasks
    SET calendar_pg_net_request_id  = v_req_id,
        calendar_pushed_complete_at = v_t.complete_at
    WHERE id = v_t.id;
    v_created := v_created + 1;
  END LOOP;

  -- 2. Read the event id back off the async response.
  FOR v_t IN
    SELECT id, calendar_pg_net_request_id
    FROM public.tasks
    WHERE agency_id = p_agency_id
      AND calendar_pg_net_request_id IS NOT NULL
      AND calendar_event_id IS NULL
  LOOP
    SELECT (resp.content::jsonb)#>>'{data,response_data,id}'
    INTO v_event_id
    FROM net._http_response resp
    WHERE resp.id = v_t.calendar_pg_net_request_id;

    IF v_event_id IS NOT NULL AND v_event_id <> '' THEN
      UPDATE public.tasks SET calendar_event_id = v_event_id WHERE id = v_t.id;
      v_captured := v_captured + 1;
    END IF;
  END LOOP;

  -- 3. Time moved: edit the same event, never a new one.
  FOR v_t IN
    SELECT id, calendar_event_id, complete_at, title
    FROM public.tasks
    WHERE agency_id = p_agency_id
      AND calendar_event_id IS NOT NULL
      AND complete_at IS NOT NULL
      AND complete_at IS DISTINCT FROM calendar_pushed_complete_at
  LOOP
    PERFORM public.composio_post(
      public.calendar_event_patch_request(
        p_agency_id, v_cal, v_t.calendar_event_id,
        v_t.complete_at, v_t.complete_at + v_len, v_t.title, NULL, 'all'));

    UPDATE public.tasks SET calendar_pushed_complete_at = v_t.complete_at WHERE id = v_t.id;
    v_patched := v_patched + 1;
  END LOOP;

  -- 4. complete_at cleared: take the event off the calendar.
  FOR v_t IN
    SELECT id, calendar_event_id
    FROM public.tasks
    WHERE agency_id = p_agency_id
      AND calendar_event_id IS NOT NULL
      AND complete_at IS NULL
  LOOP
    PERFORM public.composio_post(
      public.calendar_event_delete_request(p_agency_id, v_cal, v_t.calendar_event_id, 'all'));

    UPDATE public.tasks
    SET calendar_event_id = NULL,
        calendar_pg_net_request_id = NULL,
        calendar_pushed_complete_at = NULL
    WHERE id = v_t.id;
    v_removed := v_removed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'events_created',     v_created,
    'event_ids_captured', v_captured,
    'events_updated',     v_patched,
    'events_removed',     v_removed,
    'dispatched_at',      NOW());
END $fn$;

-- Recipe wrapper so the run log shows what happened.
CREATE OR REPLACE FUNCTION public.tasks_calendar_dispatch(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','net'
AS $fn$
DECLARE v_result jsonb;
BEGIN
  v_result := public.tasks_calendar_dispatch(p_agency_id);
  RETURN v_result || jsonb_build_object(
    'records_processed',
      COALESCE((v_result->>'events_created')::int, 0)
      + COALESCE((v_result->>'events_updated')::int, 0)
      + COALESCE((v_result->>'events_removed')::int, 0),
    'output_summary',
      COALESCE(v_result->>'skipped',
        COALESCE(v_result->>'events_created', '0') || ' created, ' ||
        COALESCE(v_result->>'event_ids_captured', '0') || ' id(s) captured, ' ||
        COALESCE(v_result->>'events_updated', '0') || ' updated, ' ||
        COALESCE(v_result->>'events_removed', '0') || ' removed'));
END $fn$;
