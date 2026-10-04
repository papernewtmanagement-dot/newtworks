CREATE OR REPLACE FUNCTION public.calendar_open_stretches(p_from timestamptz, p_to timestamptz, p_busy jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $function$
-- Open stretches between two moments given busy intervals [{s,e}] in any order. Busy in, open [{s,e}] out.
DECLARE b record; v_cur timestamptz := p_from; v_out jsonb := '[]'::jsonb;
BEGIN
  FOR b IN SELECT (x->>'s')::timestamptz s, (x->>'e')::timestamptz e FROM jsonb_array_elements(COALESCE(p_busy, '[]'::jsonb)) x
            WHERE (x->>'e')::timestamptz > p_from AND (x->>'s')::timestamptz < p_to ORDER BY 1 LOOP
    IF b.s > v_cur THEN v_out := v_out || jsonb_build_object('s', v_cur, 'e', LEAST(b.s, p_to)); END IF;
    v_cur := GREATEST(v_cur, b.e);
    EXIT WHEN v_cur >= p_to;
  END LOOP;
  IF v_cur < p_to THEN v_out := v_out || jsonb_build_object('s', v_cur, 'e', p_to); END IF;
  RETURN v_out;
END $function$;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_fit(p_open jsonb, p_queue jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $function$
-- Fits one day's coaching items into open stretches [{s,e}]. Longest item first (Peter 2026-10-04: the hour goes in the
-- morning, the half hour after it), each whole into the earliest stretch that holds it; split in 30-minute pieces only
-- when none does. Returns {placed:[{s,e,label}], carry:[{label,minutes}]} - carry rolls to the next working day.
DECLARE v_s timestamptz[]; v_e timestamptz[]; v_part jsonb; v_need int; v_take int; g int; v_ok boolean;
        v_placed jsonb := '[]'::jsonb; v_carry jsonb := '[]'::jsonb;
BEGIN
  SELECT COALESCE(array_agg((x->>'s')::timestamptz ORDER BY (x->>'s')::timestamptz), '{}'),
         COALESCE(array_agg((x->>'e')::timestamptz ORDER BY (x->>'s')::timestamptz), '{}')
    INTO v_s, v_e FROM jsonb_array_elements(COALESCE(p_open, '[]'::jsonb)) x;
  FOR v_part IN SELECT q.x FROM jsonb_array_elements(COALESCE(p_queue, '[]'::jsonb)) WITH ORDINALITY q(x, o)
                 ORDER BY (q.x->>'minutes')::int DESC, q.o LOOP
    v_need := (v_part->>'minutes')::int; v_ok := false;
    FOR g IN 1..COALESCE(cardinality(v_s), 0) LOOP
      IF extract(epoch FROM v_e[g] - v_s[g]) / 60 >= v_need THEN
        v_placed := v_placed || jsonb_build_object('s', v_s[g], 'e', v_s[g] + make_interval(mins => v_need),
                      'label', (v_part->>'label') || ' (' || v_need || ' min)');
        v_s[g] := v_s[g] + make_interval(mins => v_need); v_need := 0; v_ok := true; EXIT;
      END IF;
    END LOOP;
    IF NOT v_ok THEN
      FOR g IN 1..COALESCE(cardinality(v_s), 0) LOOP
        EXIT WHEN v_need <= 0;
        v_take := LEAST(v_need, (floor(extract(epoch FROM v_e[g] - v_s[g]) / 1800) * 30)::int);
        CONTINUE WHEN v_take < 30;
        v_placed := v_placed || jsonb_build_object('s', v_s[g], 'e', v_s[g] + make_interval(mins => v_take),
                      'label', (v_part->>'label') || ' (' || v_take || ' min)');
        v_s[g] := v_s[g] + make_interval(mins => v_take); v_need := v_need - v_take;
      END LOOP;
    END IF;
    IF v_need > 0 THEN v_carry := v_carry || jsonb_build_object('label', v_part->>'label', 'minutes', v_need); END IF;
  END LOOP;
  RETURN jsonb_build_object('placed', v_placed, 'carry', v_carry);
END $function$;

CREATE OR REPLACE FUNCTION public.set_setting(p_agency_id uuid, p_key text, p_value text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
-- Writes one settings value (the reader is get_setting).
BEGIN
  UPDATE settings SET setting_value = p_value, updated_at = now(), updated_by = 'claude'
   WHERE agency_id = p_agency_id AND setting_key = p_key;
  IF NOT FOUND THEN
    INSERT INTO settings (agency_id, setting_key, setting_value, setting_type, updated_by)
    VALUES (p_agency_id, p_key, p_value, 'text', 'claude');
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION public.standing_calendar_change_apply(p_agency_id uuid, p_change jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
-- Carries out one change the coaching layout makes to Peter's standing items (onboarding_coaching_week_layout ->
-- standing_changes): Payroll moved later in the day or canceled (Tue-Fri), Admin canceled. His State Farm email,
-- the only invitee, gets the update. A failure leaves an alert.
DECLARE v_res jsonb;
BEGIN
  BEGIN
    IF p_change->>'action' = 'move' THEN
      v_res := public.calendar_patch_event_now(p_agency_id, 'primary', p_change->>'event_id', (p_change->>'start')::timestamptz,
                 (p_change->>'end')::timestamptz, NULL, NULL, NULL, NULL, 'all');
    ELSE
      v_res := public.calendar_delete_event_now(p_agency_id, 'primary', p_change->>'event_id');
    END IF;
  EXCEPTION WHEN OTHERS THEN v_res := jsonb_build_object('ok', false, 'error', SQLERRM); END;
  IF COALESCE((v_res->>'ok')::boolean, false) THEN RETURN true; END IF;
  INSERT INTO alerts (agency_id, alert_type, severity, title, message, module_reference)
  VALUES (p_agency_id, 'automation_failure', 'warning', 'Standing calendar item not updated',
          CASE WHEN p_change->>'action' = 'move' THEN 'Move ' ELSE 'Remove ' END || COALESCE(p_change->>'kind', 'item') || ' on ' ||
          COALESCE(to_char((p_change->>'date')::date, 'Dy Mon FMDD'), '?') || ' by hand. ' || COALESCE(v_res->>'error', ''), 'onboarding');
  RETURN false;
END $function$;

CREATE OR REPLACE FUNCTION public.onboarding_coaching_week_layout(p_plan_id uuid, p_week_no integer, p_from date, p_until date, p_place_from date DEFAULT NULL::date, p_skip_event_ids text[] DEFAULT '{}'::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where Peter's coaching time for one week of a hire's plan goes (onboarding_coaching_blocks_plan), never
-- double-booking anything (Peter 2026-10-04).
--   Day k of the plan = the k-th working day from p_from (a weekday, not a company holiday, not Peter's approved time
--   off), before p_until (the next week's open date). Days before p_place_from are already past and get nothing.
--   Busy = his calendar's events (calendar_busy_now, less p_skip_event_ids: the week's own blocks when re-placing)
--   plus every interview time, booked or open (interview_slot_grid, less slots he blacked out). An interview time whose
--   day has started unbooked is free again (its hold has come off); a booked one is a calendar event anyway.
--   His standing items give way (Peter 2026-10-04): Admin (settings standing_admin_event_id) is removed where coaching
--   needs it; Payroll (standing_payroll_event_id) moves later that day, or Tue-Fri is canceled if nothing later is open;
--   Monday Payroll only moves, so when it can't, it stays and coaching works around it.
--   Open time 9:00-17:00 Central. Items fit by onboarding_coaching_fit (longest first, whole where possible, split in
--   30-minute pieces only when needed). Time that doesn't fit its day rolls to the next working day (day 1 spills to
--   day 2), ahead of that day's own items. Back-to-back items are one block.
-- Returns {pieces:[{day,date,start,end,lines}], unplaced_minutes, unplaced, standing_changes:[{kind,action,event_id,
-- date,start,end}]}, or NULL when the calendar can't be read. Callers apply standing_changes via standing_calendar_change_apply.
DECLARE
  v_agency uuid; v_owner uuid; v_days date[] := '{}'; v_d date; v_n int; v_i int; v_k int;
  v_plan jsonb; v_byday jsonb := '{}'::jsonb; v_carry jsonb := '[]'::jsonb; v_queue jsonb; v_part jsonb;
  v_ws timestamptz; v_we timestamptz; v_busy jsonb; v_hard jsonb; v_pay jsonb; v_adm jsonb; v_pay_id text; v_adm_id text;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date; v_fit jsonb; v_pay_hard boolean; v_keep_admin boolean;
  v_open jsonb; v_mv timestamptz; v_dur interval; v_changes jsonb := '[]'::jsonb; v_day_changes jsonb;
  v_pieces jsonb := '[]'::jsonb; x jsonb; v_s timestamptz; v_e timestamptz; v_lines text[]; v_placed_busy jsonb;
BEGIN
  SELECT agency_id INTO v_agency FROM team_onboarding_plans WHERE id = p_plan_id;
  IF v_agency IS NULL THEN RETURN NULL; END IF;
  SELECT id INTO v_owner FROM team WHERE agency_id = v_agency AND role_level = 'Owner' ORDER BY created_at LIMIT 1;
  v_pay_id := NULLIF(btrim(COALESCE(public.get_setting(v_agency, 'standing_payroll_event_id'), '')), '');
  v_adm_id := NULLIF(btrim(COALESCE(public.get_setting(v_agency, 'standing_admin_event_id'), '')), '');

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
    RETURN jsonb_build_object('pieces', '[]'::jsonb, 'standing_changes', '[]'::jsonb, 'unplaced_minutes',
      COALESCE((SELECT sum((y->>'minutes')::int) FROM jsonb_array_elements(v_plan) y), 0), 'unplaced', '[]'::jsonb);
  END IF;
  FOR v_part IN SELECT y FROM jsonb_array_elements(v_plan) y LOOP
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

    v_pay := NULL; v_adm := NULL; v_hard := '[]'::jsonb;
    FOR x IN SELECT y FROM jsonb_array_elements(v_busy) y WHERE NOT COALESCE(y->>'id' = ANY(p_skip_event_ids), false) LOOP
      IF v_pay_id IS NOT NULL AND (x->>'id' = v_pay_id OR left(x->>'id', length(v_pay_id) + 1) = v_pay_id || '_') THEN v_pay := x;
      ELSIF v_adm_id IS NOT NULL AND (x->>'id' = v_adm_id OR left(x->>'id', length(v_adm_id) + 1) = v_adm_id || '_') THEN v_adm := x;
      ELSE v_hard := v_hard || jsonb_build_object('s', x->'start', 'e', x->'end'); END IF;
    END LOOP;
    v_hard := v_hard || COALESCE((SELECT jsonb_agg(jsonb_build_object('s', g.start_at, 'e', g.end_at))
                FROM public.interview_slot_grid(v_agency, v_days[v_i], v_days[v_i]) g
               WHERE NOT g.blacked_out AND g.slot_date > v_today), '[]'::jsonb);

    v_pay_hard := false;
    LOOP
      v_fit := public.onboarding_coaching_fit(public.calendar_open_stretches(v_ws, v_we, v_hard ||
                 CASE WHEN v_pay_hard THEN jsonb_build_array(jsonb_build_object('s', v_pay->'start', 'e', v_pay->'end')) ELSE '[]'::jsonb END),
                 v_queue);
      v_day_changes := '[]'::jsonb; v_keep_admin := true;
      IF v_adm IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_fit->'placed') p
           WHERE (p->>'s')::timestamptz < (v_adm->>'end')::timestamptz AND (p->>'e')::timestamptz > (v_adm->>'start')::timestamptz) THEN
        v_keep_admin := false;
        v_day_changes := v_day_changes || jsonb_build_object('kind', 'Admin', 'action', 'cancel', 'event_id', v_adm->>'id',
                           'date', v_days[v_i], 'start', v_adm->'start', 'end', v_adm->'end');
      END IF;
      EXIT WHEN v_pay IS NULL OR v_pay_hard OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_fit->'placed') p
           WHERE (p->>'s')::timestamptz < (v_pay->>'end')::timestamptz AND (p->>'e')::timestamptz > (v_pay->>'start')::timestamptz);
      v_dur := (v_pay->>'end')::timestamptz - (v_pay->>'start')::timestamptz;
      v_placed_busy := COALESCE((SELECT jsonb_agg(jsonb_build_object('s', p->'s', 'e', p->'e')) FROM jsonb_array_elements(v_fit->'placed') p), '[]'::jsonb);
      v_open := public.calendar_open_stretches(v_ws, v_we, v_hard || v_placed_busy ||
                  CASE WHEN v_keep_admin AND v_adm IS NOT NULL THEN jsonb_build_array(jsonb_build_object('s', v_adm->'start', 'e', v_adm->'end')) ELSE '[]'::jsonb END);
      SELECT GREATEST((o->>'s')::timestamptz, (v_pay->>'start')::timestamptz) INTO v_mv FROM jsonb_array_elements(v_open) o
       WHERE (o->>'e')::timestamptz - GREATEST((o->>'s')::timestamptz, (v_pay->>'start')::timestamptz) >= v_dur ORDER BY 1 LIMIT 1;
      IF v_mv IS NOT NULL THEN
        v_day_changes := v_day_changes || jsonb_build_object('kind', 'Payroll', 'action', 'move', 'event_id', v_pay->>'id',
                           'date', v_days[v_i], 'start', v_mv, 'end', v_mv + v_dur);
        EXIT;
      ELSIF extract(isodow FROM v_days[v_i]) = 1 THEN
        v_pay_hard := true;
      ELSE
        v_day_changes := v_day_changes || jsonb_build_object('kind', 'Payroll', 'action', 'cancel', 'event_id', v_pay->>'id',
                           'date', v_days[v_i], 'start', v_pay->'start', 'end', v_pay->'end');
        EXIT;
      END IF;
    END LOOP;
    v_changes := v_changes || v_day_changes;
    v_carry := v_fit->'carry';

    v_s := NULL;
    FOR x IN SELECT p FROM jsonb_array_elements(v_fit->'placed') p ORDER BY (p->>'s')::timestamptz LOOP
      IF v_s IS NOT NULL AND (x->>'s')::timestamptz = v_e THEN
        v_e := (x->>'e')::timestamptz; v_lines := v_lines || (x->>'label');
      ELSE
        IF v_s IS NOT NULL THEN
          v_pieces := v_pieces || jsonb_build_object('day', v_i, 'date', v_days[v_i], 'start', v_s, 'end', v_e, 'lines', to_jsonb(v_lines));
        END IF;
        v_s := (x->>'s')::timestamptz; v_e := (x->>'e')::timestamptz; v_lines := ARRAY[x->>'label'];
      END IF;
    END LOOP;
    IF v_s IS NOT NULL THEN
      v_pieces := v_pieces || jsonb_build_object('day', v_i, 'date', v_days[v_i], 'start', v_s, 'end', v_e, 'lines', to_jsonb(v_lines));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('pieces', v_pieces, 'unplaced', v_carry, 'standing_changes', v_changes,
    'unplaced_minutes', COALESCE((SELECT sum((y->>'minutes')::int) FROM jsonb_array_elements(v_carry) y), 0));
END $function$;

DO $do$
DECLARE d text; n text;
BEGIN
  d := pg_get_functiondef('public.onboarding_coaching_blocks_sync(uuid,boolean,timestamptz)'::regprocedure);
  n := replace(d, $x$      IF NOT p_dry_run THEN v_events := v_events || jsonb_build_object(w.week_no::text, v_week); END IF;$x$,
$x$      IF NOT p_dry_run THEN
        v_events := v_events || jsonb_build_object(w.week_no::text, v_week);
        -- Payroll moved later or canceled, Admin removed, where this week's coaching needs the time (standing_calendar_change_apply)
        FOR e IN SELECT x FROM jsonb_array_elements(COALESCE(v_lay->'standing_changes', '[]'::jsonb)) x LOOP
          PERFORM public.standing_calendar_change_apply(p_agency_id, e);
        END LOOP;
      ELSE
        v_preview := v_preview || jsonb_build_object('week', w.week_no, 'standing_changes', COALESCE(v_lay->'standing_changes', '[]'::jsonb));
      END IF;$x$);
  IF n = d THEN RAISE EXCEPTION 'sync: anchor not found'; END IF;
  EXECUTE n;

  d := pg_get_functiondef('public.onboarding_coaching_week_replace(uuid,integer,boolean,timestamptz)'::regprocedure);
  n := replace(d, $x$  UPDATE team_onboarding_plans SET coaching_events = jsonb_set($x$,
$x$  -- Payroll moved later or canceled, Admin removed, where the re-placed coaching needs the time
  FOR f IN SELECT x FROM jsonb_array_elements(COALESCE(v_lay->'standing_changes', '[]'::jsonb)) x LOOP
    IF NOT public.standing_calendar_change_apply(v_agency, f) THEN v_failed := v_failed + 1; END IF;
  END LOOP;
  UPDATE team_onboarding_plans SET coaching_events = jsonb_set($x$);
  IF n = d THEN RAISE EXCEPTION 'replace: anchor not found'; END IF;
  EXECUTE n;
END $do$;
