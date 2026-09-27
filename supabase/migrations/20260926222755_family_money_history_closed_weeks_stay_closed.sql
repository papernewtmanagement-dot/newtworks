-- Family money: one history of every event (Peter 2026-09-26, "the money tab isn't adding up"),
-- and closed weeks stay closed.

-- 1. The one money history: the opening balance plus every week's events, each marked posted or
--    still pending the close-out, with spending money after each line. family_kid_money sums it.
CREATE OR REPLACE FUNCTION public.family_money_history(p_kid_id uuid, p_through_week date)
 RETURNS TABLE(week_start date, closed boolean, posted boolean, seq integer, event_date date, kind text, label text, bucket text, amount numeric, is_income boolean, tithe numeric, invest numeric, ref_id uuid, math_done boolean, spend_after numeric)
 LANGUAGE sql
 STABLE
AS $function$
  WITH k AS (SELECT tracking_start FROM public.family_kids WHERE id = p_kid_id),
  weeks AS (
    SELECT w::date AS ws FROM k,
    generate_series(public.family_week_start(k.tracking_start), p_through_week, interval '7 days') w
  ),
  ev AS (
    SELECT (SELECT min(ws) FROM weeks) AS ws, true AS closed, true AS posted, 0 AS seq, min(g.entry_date) AS event_date,
           'opening_balance'::text AS kind, 'Starting balance'::text AS label, 'spend'::text AS bucket, sum(g.amount) AS amount,
           false AS is_income, 0::numeric AS tithe, 0::numeric AS invest, NULL::uuid AS ref_id, false AS math_done
    FROM public.family_ledger g WHERE g.kid_id = p_kid_id AND g.kind = 'opening_balance'
    HAVING count(*) > 0
    UNION ALL
    SELECT weeks.ws, fw.id IS NOT NULL, ((fw.id IS NOT NULL) OR e.kind NOT IN ('chore_pay','fines','fine','expense')),
           e.seq, e.event_date, e.kind, e.label, e.bucket, e.amount, e.is_income, e.tithe, e.invest, e.ref_id, e.math_done
    FROM weeks
    LEFT JOIN public.family_weeks fw ON fw.kid_id = p_kid_id AND fw.week_start = weeks.ws
    CROSS JOIN LATERAL public.family_week_events(p_kid_id, weeks.ws) e
  )
  SELECT ev.ws, ev.closed, ev.posted, ev.seq, ev.event_date, ev.kind, ev.label, ev.bucket, ev.amount, ev.is_income, ev.tithe, ev.invest, ev.ref_id, ev.math_done,
         sum(CASE WHEN ev.posted THEN (CASE WHEN ev.bucket = 'spend' THEN ev.amount ELSE 0 END) - ev.tithe - ev.invest ELSE 0 END)
           OVER (ORDER BY ev.ws, ev.seq ROWS UNBOUNDED PRECEDING)
  FROM ev
  ORDER BY ev.ws, ev.seq;
$function$;
REVOKE ALL ON FUNCTION public.family_money_history(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_money_history(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.family_kid_money(p_kid_id uuid, p_through_week date)
 RETURNS TABLE(spend numeric, tithe numeric, invest numeric, pending numeric)
 LANGUAGE sql
 STABLE
AS $function$
  -- Sums the one money history (family_money_history).
  SELECT COALESCE(sum(h.amount) FILTER (WHERE h.bucket = 'spend' AND h.posted), 0)
           - COALESCE(sum(h.tithe + h.invest) FILTER (WHERE h.posted), 0),
         COALESCE(sum(h.amount) FILTER (WHERE h.bucket = 'tithe' AND h.posted), 0) + COALESCE(sum(h.tithe) FILTER (WHERE h.posted), 0),
         COALESCE(sum(h.amount) FILTER (WHERE h.bucket = 'invest' AND h.posted), 0) + COALESCE(sum(h.invest) FILTER (WHERE h.posted), 0),
         COALESCE(sum(h.amount) FILTER (WHERE NOT h.posted), 0)
  FROM public.family_money_history(p_kid_id, p_through_week) h;
$function$;

-- 2. A closed week never changes. The sweep marked a missed day inside Bella's closed week after
--    her due day was moved (Sep 26 22:24); that fine comes back off, and the sweep and
--    family_set_status no longer write into a closed week.
DELETE FROM public.family_chore_log l USING public.family_weeks f
WHERE f.kid_id = l.kid_id AND f.week_start = public.family_week_start(l.occurrence_date)
  AND l.created_at > f.closed_at AND l.updated_by IS NULL AND l.status = 'missed';

CREATE OR REPLACE FUNCTION public.family_week_closed(p_kid_id uuid, p_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.family_weeks f WHERE f.kid_id = p_kid_id AND f.week_start = public.family_week_start(p_date));
$function$;
REVOKE ALL ON FUNCTION public.family_week_closed(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_week_closed(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.family_sweep_missed()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE v_today date := (now() AT TIME ZONE 'America/Chicago')::date; n int; m int;
BEGIN
  DELETE FROM public.family_chore_log l USING public.family_chores c
  WHERE c.id = l.chore_id AND c.frequency = 'extra' AND l.status = 'picked' AND l.occurrence_date < v_today;

  -- An overdue-day entry whose chore turns out not to be overdue that day (a parent changed an
  -- earlier day) comes back off, in weeks not yet closed.
  DELETE FROM public.family_chore_log l USING public.family_chores c
  WHERE c.id = l.chore_id AND c.frequency = 'weekly'
    AND l.occurrence_date IS DISTINCT FROM public.family_occurrence_date(l.chore_id, l.occurrence_date)
    AND public.family_overdue_from(l.chore_id, l.occurrence_date) IS NULL
    AND NOT public.family_week_closed(l.kid_id, l.occurrence_date);

  WITH base AS (
    SELECT c.id, c.kid_id, c.agency_id, c.frequency, c.active_to,
           GREATEST(k.tracking_start, c.active_from) AS start_d
    FROM public.family_chores c
    JOIN public.family_kids k ON k.id = c.kid_id AND k.is_active
    WHERE c.frequency IN ('daily','weekly')
  ), occ AS (
    SELECT b.id AS chore_id, b.kid_id, b.agency_id, b.start_d, b.active_to, d::date AS occurrence_date
    FROM base b CROSS JOIN LATERAL generate_series(b.start_d, v_today - 1, interval '1 day') d
    WHERE b.frequency = 'daily'
    UNION ALL
    SELECT b.id, b.kid_id, b.agency_id, b.start_d, b.active_to, public.family_occurrence_date(b.id, w::date)
    FROM base b CROSS JOIN LATERAL generate_series(public.family_week_start(b.start_d), public.family_week_start(v_today), interval '7 days') w
    WHERE b.frequency = 'weekly'
  ), ins AS (
    INSERT INTO public.family_chore_log (agency_id, chore_id, kid_id, occurrence_date, status, amount)
    SELECT o.agency_id, o.chore_id, o.kid_id, o.occurrence_date, 'missed', public.family_log_amount(o.chore_id, 'missed', o.occurrence_date)
    FROM occ o
    WHERE o.occurrence_date >= o.start_d AND o.occurrence_date < v_today
      AND (o.active_to IS NULL OR o.occurrence_date <= o.active_to)
      AND NOT public.family_week_closed(o.kid_id, o.occurrence_date)
    ON CONFLICT (chore_id, occurrence_date, slot) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;

  -- Each past overdue day of a weekly chore (family_overdue_from) is fined like a missed day.
  -- Only weeks not yet closed are looked at; weeks close in order.
  WITH days AS (
    SELECT c.id AS chore_id, c.kid_id, c.agency_id, d::date AS d
    FROM public.family_chores c
    JOIN public.family_kids k ON k.id = c.kid_id AND k.is_active
    CROSS JOIN LATERAL generate_series(
      GREATEST(k.tracking_start, c.active_from,
               COALESCE((SELECT max(f.week_start) + 7 FROM public.family_weeks f WHERE f.kid_id = k.id), public.family_week_start(k.tracking_start))),
      v_today - 1, interval '1 day') d
    WHERE c.frequency = 'weekly'
  ), ins AS (
    INSERT INTO public.family_chore_log (agency_id, chore_id, kid_id, occurrence_date, status, amount)
    SELECT x.agency_id, x.chore_id, x.kid_id, x.d, 'missed', public.family_log_amount(x.chore_id, 'missed', x.d)
    FROM days x
    WHERE public.family_overdue_from(x.chore_id, x.d) IS NOT NULL
      AND NOT public.family_week_closed(x.kid_id, x.d)
    ON CONFLICT (chore_id, occurrence_date, slot) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO m FROM ins;
  RETURN n + m;
END $function$;

CREATE OR REPLACE FUNCTION public.family_set_status(p_chore_id uuid, p_occurrence_date date, p_status text, p_note text DEFAULT NULL::text, p_kid_id uuid DEFAULT NULL::uuid, p_slot smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE v_c public.family_chores; v_occ date; v_cur text; v_cur_kid uuid; v_kid uuid; v_slot smallint;
        v_parent boolean := public.family_is_parent(); v_count int; v_row public.family_chore_log; v_lock text;
BEGIN
  SELECT * INTO v_c FROM public.family_chores WHERE id = p_chore_id;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'Chore not found.'; END IF;
  v_occ := public.family_occurrence_date(p_chore_id, p_occurrence_date);
  -- A weekly chore on one of its overdue days is logged on that day (Peter 2026-09-26).
  IF v_c.frequency = 'weekly' AND v_occ IS DISTINCT FROM p_occurrence_date
     AND public.family_overdue_from(p_chore_id, p_occurrence_date) IS NOT NULL THEN
    v_occ := p_occurrence_date;
  END IF;
  -- An every-other-week chore in its off week (Peter 2026-09-24).
  IF v_occ IS NULL THEN RAISE EXCEPTION 'That chore is off this week.'; END IF;
  IF p_status = 'picked' AND v_c.frequency = 'extra' AND v_c.repeat_days = 0 AND p_slot IS NULL THEN
    SELECT COALESCE(max(slot), 0) + 1 INTO v_slot FROM public.family_chore_log WHERE chore_id = p_chore_id AND occurrence_date = v_occ;
  ELSE
    v_slot := COALESCE(p_slot, 1);
  END IF;
  SELECT status, kid_id INTO v_cur, v_cur_kid FROM public.family_chore_log
   WHERE chore_id = p_chore_id AND occurrence_date = v_occ AND slot = v_slot;
  IF v_c.frequency = 'extra' AND v_cur_kid IS NOT NULL AND p_kid_id IS NOT NULL AND v_cur_kid <> p_kid_id THEN
    RAISE EXCEPTION 'Someone else already took that one.';
  END IF;
  v_kid := COALESCE(v_c.kid_id, v_cur_kid, p_kid_id);
  IF v_kid IS NULL THEN RAISE EXCEPTION 'Pick a kid first.'; END IF;
  -- A closed-out week never changes (Peter 2026-09-26).
  IF public.family_week_closed(v_kid, v_occ) THEN RAISE EXCEPTION 'That week is closed out.'; END IF;
  IF v_c.frequency = 'extra' AND p_status IN ('missed','false_claim','excused','carried') THEN
    RAISE EXCEPTION 'Extra chores are never fined. Undo it instead.';
  END IF;
  IF NOT v_parent THEN
    IF p_status IS NULL AND v_cur IS DISTINCT FROM 'picked' THEN RAISE EXCEPTION 'Only a parent can undo that.'; END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('claimed','missed','picked') THEN RAISE EXCEPTION 'Only a parent can do that.'; END IF;
    IF v_cur IN ('missed','false_claim','excused','verified','carried') THEN RAISE EXCEPTION 'Only a parent can change that.'; END IF;
  END IF;
  IF p_status = 'carried' AND NOT v_c.is_burpees THEN RAISE EXCEPTION 'Only burpees can be carried.'; END IF;
  IF p_status = 'picked' AND v_c.frequency <> 'extra' THEN RAISE EXCEPTION 'Only extra chores can be picked.'; END IF;
  IF v_c.frequency = 'daily' AND v_cur IS NULL
     AND (p_status IN ('claimed','carried') OR (p_status = 'missed' AND NOT v_parent)) THEN
    v_lock := public.family_part_locked(v_kid, v_occ, v_c.part_of_day);
    IF v_lock IS NOT NULL THEN RAISE EXCEPTION 'Finish % first.', v_lock; END IF;
  END IF;
  IF p_status IS NULL THEN
    DELETE FROM public.family_chore_log WHERE chore_id = p_chore_id AND occurrence_date = v_occ AND slot = v_slot;
    RETURN jsonb_build_object('cleared', true);
  END IF;
  IF p_status = 'carried' THEN v_count := public.family_burpees_owed(p_chore_id, v_occ); END IF;
  INSERT INTO public.family_chore_log (agency_id, chore_id, kid_id, occurrence_date, slot, status, amount, note, updated_by, burpee_count)
  VALUES (v_c.agency_id, p_chore_id, v_kid, v_occ, v_slot, p_status, public.family_log_amount(p_chore_id, p_status, v_occ), p_note, auth.uid(), v_count)
  ON CONFLICT (chore_id, occurrence_date, slot) DO UPDATE
    SET status = EXCLUDED.status, amount = EXCLUDED.amount,
        note = COALESCE(EXCLUDED.note, public.family_chore_log.note),
        updated_by = EXCLUDED.updated_by, burpee_count = EXCLUDED.burpee_count, updated_at = now()
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $function$;
