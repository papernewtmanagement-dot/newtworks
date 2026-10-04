
CREATE OR REPLACE FUNCTION public.calendar_busy_now(p_agency_id uuid, p_calendar_id text, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
-- Busy times on a Google Calendar between two moments, read from its events: [{id, start, end}].
-- Skips all-day items, events marked free, canceled events and anything 12 hours or longer (holiday markers).
-- NULL when the calendar can't be read; callers must never place anything blind.
DECLARE r jsonb; res jsonb;
BEGIN
  BEGIN
    r := public.composio_tool_request(p_agency_id, 'GOOGLECALENDAR_EVENTS_LIST', jsonb_build_object(
      'calendarId', p_calendar_id, 'singleEvents', true, 'orderBy', 'startTime', 'maxResults', 250,
      'timeMin', to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'timeMax', to_char(p_to AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'fields', 'items(id,start,end,transparency,status)'));
    res := public.composio_post_now(r);
  EXCEPTION WHEN OTHERS THEN RETURN NULL; END;
  IF NOT COALESCE((res->>'ok')::boolean, false) OR jsonb_typeof(res #> '{data,items}') IS DISTINCT FROM 'array' THEN RETURN NULL; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', id, 'start', s, 'end', e) ORDER BY s)
      FROM (SELECT x->>'id' id, (x #>> '{start,dateTime}')::timestamptz s, (x #>> '{end,dateTime}')::timestamptz e
              FROM jsonb_array_elements(COALESCE(res #> '{data,items}', '[]'::jsonb)) x
             WHERE x #>> '{start,dateTime}' IS NOT NULL
               AND COALESCE(x->>'transparency', 'opaque') <> 'transparent'
               AND COALESCE(x->>'status', 'confirmed') <> 'cancelled') q
     WHERE e - s < interval '12 hours'), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_invitees(p_agency_id uuid)
 RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
-- Who gets invited to Peter's coaching blocks: his State Farm email, plus every active new hire's State Farm email
-- (never a personal one) while setting onboarding_coaching_invite_hires = 'true'. Off since 2026-10-04: Peter said
-- to stop inviting Bryson for now.
SELECT ARRAY(SELECT DISTINCT x FROM (
  SELECT NULLIF(btrim(t.email_sf), '') AS x FROM (SELECT email_sf FROM team WHERE agency_id = p_agency_id AND role_level = 'Owner'
                                                    ORDER BY created_at LIMIT 1) t
  UNION ALL
  SELECT NULLIF(btrim(t2.email_sf), '') FROM team_onboarding_plans p2 JOIN team t2 ON t2.id = p2.team_member_id
   WHERE p2.agency_id = p_agency_id AND p2.status = 'active'
     AND COALESCE(public.get_setting(p_agency_id, 'onboarding_coaching_invite_hires'), 'false') = 'true') q
 WHERE x IS NOT NULL ORDER BY x);
$function$;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_event_text(p_plan_id uuid, p_week_no integer, p_lines jsonb)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
-- Title and description of one coaching block: "Coaching: <first name>, Week <n>", the items it covers, the plan link.
SELECT jsonb_build_object(
  'summary', 'Coaching: ' || COALESCE(NULLIF(btrim(COALESCE(t.nickname, t.first_name)), ''), NULLIF(btrim(c.first_name), ''), 'new hire') || ', Week ' || p_week_no,
  'description', (SELECT string_agg(x, E'\n') FROM jsonb_array_elements_text(p_lines) x) || E'\n\nPlan: ' ||
                 COALESCE(public.get_setting(pl.agency_id, 'app_base_url'), 'https://newtworks.vercel.app') || '/onboarding?plan=' || pl.id)
  FROM team_onboarding_plans pl
  LEFT JOIN team t ON t.id = pl.team_member_id
  LEFT JOIN hiring_candidates c ON c.id = pl.candidate_id
 WHERE pl.id = p_plan_id;
$function$;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_week_layout(p_plan_id uuid, p_week_no integer, p_from date, p_until date,
  p_place_from date DEFAULT NULL, p_skip_event_ids text[] DEFAULT '{}'::text[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
-- Where Peter's coaching time for one week of a hire's plan goes (onboarding_coaching_blocks_plan), never
-- double-booking anything (Peter 2026-10-04).
--   Day k of the plan = the k-th working day from p_from (a weekday, not a company holiday, not Peter's approved time
--   off), before p_until (the next week's open date). Days before p_place_from are already past and get nothing.
--   Busy = his calendar's events (calendar_busy_now, less p_skip_event_ids: the week's own blocks when re-placing)
--   plus every interview time, booked or open (interview_slot_grid, less slots he blacked out).
--   Open time is 9:00 to 17:00 Central. Each item goes whole into the earliest open stretch that holds it; only when
--   none does is it split, in 30-minute pieces (Peter: "my time with a new hire can be split if needed"). Time that
--   doesn't fit its day rolls to the next working day, ahead of that day's own items. Back-to-back items are one block.
-- Returns {pieces:[{day, date, start, end, lines}], unplaced_minutes, unplaced}, or NULL when the calendar can't be read.
DECLARE
  v_agency uuid; v_owner uuid; v_days date[] := '{}'; v_d date; v_n int; v_i int; v_k int; j int;
  v_plan jsonb; v_byday jsonb := '{}'::jsonb; v_carry jsonb := '[]'::jsonb; v_queue jsonb; v_part jsonb;
  v_ws timestamptz; v_we timestamptz; v_busy jsonb; b record; v_cur timestamptz;
  v_gs timestamptz[]; v_ge timestamptz[]; v_ps timestamptz[]; v_pe timestamptz[]; v_pl text[];
  v_need int; v_take int; v_g int; v_placed boolean; v_s timestamptz; v_e timestamptz; v_lines text[];
  v_pieces jsonb := '[]'::jsonb;
BEGIN
  SELECT agency_id INTO v_agency FROM team_onboarding_plans WHERE id = p_plan_id;
  IF v_agency IS NULL THEN RETURN NULL; END IF;
  SELECT id INTO v_owner FROM team WHERE agency_id = v_agency AND role_level = 'Owner' ORDER BY created_at LIMIT 1;

  v_d := p_from;
  WHILE cardinality(v_days) < 5 AND (p_until IS NULL OR v_d < p_until) AND v_d < p_from + 21 LOOP
    IF extract(isodow FROM v_d) <= 5
       AND NOT EXISTS (SELECT 1 FROM company_holidays h WHERE h.agency_id = v_agency AND h.is_active AND h.holiday_date = v_d)
       AND NOT EXISTS (SELECT 1 FROM time_off_requests r WHERE r.agency_id = v_agency AND r.requester_team_id = v_owner
                        AND r.status = 'approved' AND v_d BETWEEN r.start_date AND COALESCE(r.end_date, r.start_date)) THEN
      v_days := v_days || v_d;
    END IF;
    v_d := v_d + 1;
  END LOOP;
  v_n := cardinality(v_days);

  v_plan := public.onboarding_coaching_blocks_plan(p_plan_id, p_week_no);
  IF v_n = 0 THEN
    RETURN jsonb_build_object('pieces', '[]'::jsonb, 'unplaced_minutes',
      COALESCE((SELECT sum((x->>'minutes')::int) FROM jsonb_array_elements(v_plan) x), 0), 'unplaced', '[]'::jsonb);
  END IF;
  FOR v_part IN SELECT x FROM jsonb_array_elements(v_plan) x LOOP
    v_k := LEAST((v_part->>'day')::int, v_n);
    v_byday := jsonb_set(v_byday, ARRAY[v_k::text], COALESCE(v_byday->(v_k::text), '[]'::jsonb) || (v_part->'parts'));
  END LOOP;

  FOR v_i IN 1..v_n LOOP
    CONTINUE WHEN p_place_from IS NOT NULL AND v_days[v_i] < p_place_from;
    v_queue := v_carry || COALESCE(v_byday->(v_i::text), '[]'::jsonb);
    v_carry := '[]'::jsonb;
    CONTINUE WHEN jsonb_array_length(v_queue) = 0;
    v_ws := (v_days[v_i] + time '09:00') AT TIME ZONE 'America/Chicago';
    v_we := (v_days[v_i] + time '17:00') AT TIME ZONE 'America/Chicago';
    v_busy := public.calendar_busy_now(v_agency, 'primary', v_ws, v_we);
    IF v_busy IS NULL THEN RETURN NULL; END IF;

    v_gs := '{}'; v_ge := '{}'; v_cur := v_ws;
    FOR b IN
      SELECT q.s, q.e FROM (
        SELECT (x->>'start')::timestamptz s, (x->>'end')::timestamptz e FROM jsonb_array_elements(v_busy) x
         WHERE NOT COALESCE(x->>'id' = ANY(p_skip_event_ids), false)
        UNION ALL
        SELECT g.start_at, g.end_at FROM public.interview_slot_grid(v_agency, v_days[v_i], v_days[v_i]) g WHERE NOT g.blacked_out
      ) q WHERE q.e > v_ws AND q.s < v_we ORDER BY q.s
    LOOP
      IF b.s > v_cur THEN v_gs := v_gs || v_cur; v_ge := v_ge || LEAST(b.s, v_we); END IF;
      v_cur := GREATEST(v_cur, b.e);
      EXIT WHEN v_cur >= v_we;
    END LOOP;
    IF v_cur < v_we THEN v_gs := v_gs || v_cur; v_ge := v_ge || v_we; END IF;

    v_ps := '{}'; v_pe := '{}'; v_pl := '{}';
    FOR v_part IN SELECT x FROM jsonb_array_elements(v_queue) x LOOP
      v_need := (v_part->>'minutes')::int; v_placed := false;
      FOR v_g IN 1..COALESCE(cardinality(v_gs), 0) LOOP
        IF extract(epoch FROM v_ge[v_g] - v_gs[v_g]) / 60 >= v_need THEN
          v_ps := v_ps || v_gs[v_g]; v_pe := v_pe || (v_gs[v_g] + make_interval(mins => v_need));
          v_pl := v_pl || ((v_part->>'label') || ' (' || v_need || ' min)');
          v_gs[v_g] := v_gs[v_g] + make_interval(mins => v_need);
          v_need := 0; v_placed := true; EXIT;
        END IF;
      END LOOP;
      IF NOT v_placed THEN
        FOR v_g IN 1..COALESCE(cardinality(v_gs), 0) LOOP
          EXIT WHEN v_need <= 0;
          v_take := LEAST(v_need, (floor(extract(epoch FROM v_ge[v_g] - v_gs[v_g]) / 1800) * 30)::int);
          CONTINUE WHEN v_take < 30;
          v_ps := v_ps || v_gs[v_g]; v_pe := v_pe || (v_gs[v_g] + make_interval(mins => v_take));
          v_pl := v_pl || ((v_part->>'label') || ' (' || v_take || ' min)');
          v_gs[v_g] := v_gs[v_g] + make_interval(mins => v_take);
          v_need := v_need - v_take;
        END LOOP;
      END IF;
      IF v_need > 0 THEN v_carry := v_carry || jsonb_build_object('label', v_part->>'label', 'minutes', v_need); END IF;
    END LOOP;

    v_s := NULL;
    FOR j IN SELECT u.o FROM unnest(v_ps) WITH ORDINALITY u(t, o) ORDER BY u.t LOOP
      IF v_s IS NOT NULL AND v_ps[j] = v_e THEN
        v_e := v_pe[j]; v_lines := v_lines || v_pl[j];
      ELSE
        IF v_s IS NOT NULL THEN
          v_pieces := v_pieces || jsonb_build_object('day', v_i, 'date', v_days[v_i], 'start', v_s, 'end', v_e, 'lines', to_jsonb(v_lines));
        END IF;
        v_s := v_ps[j]; v_e := v_pe[j]; v_lines := ARRAY[v_pl[j]];
      END IF;
    END LOOP;
    IF v_s IS NOT NULL THEN
      v_pieces := v_pieces || jsonb_build_object('day', v_i, 'date', v_days[v_i], 'start', v_s, 'end', v_e, 'lines', to_jsonb(v_lines));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('pieces', v_pieces, 'unplaced', v_carry,
    'unplaced_minutes', COALESCE((SELECT sum((x->>'minutes')::int) FROM jsonb_array_elements(v_carry) x), 0));
END $function$;
