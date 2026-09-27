-- Overdue weekly chores (Peter 2026-09-26): a weekly chore not done on its due day shows up
-- the next day to be checked, says how many days overdue it is, and is fined every day it is
-- still not done.

CREATE OR REPLACE FUNCTION public.family_overdue_from(p_chore_id uuid, p_date date)
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
  -- The one overdue rule (Peter 2026-09-26). A weekly chore that is not done on its due day
  -- stays on the board every day after, and each of those days is fined like a missed chore,
  -- until it is done (Done, Checked, Excused) or it comes due again, when the new one takes over.
  -- Returns the due date the chore is overdue from on p_date, or NULL when p_date is not an
  -- overdue day for it. The rule started 2026-09-26; days before that stay as they were.
  WITH c AS (
    SELECT c.id, c.due_dow, COALESCE(c.every_weeks, 1) AS n, c.active_to,
           GREATEST(k.tracking_start, c.active_from) AS start_d
    FROM public.family_chores c JOIN public.family_kids k ON k.id = c.kid_id
    WHERE c.id = p_chore_id AND c.frequency = 'weekly'
  ),
  due AS (
    SELECT c.*, (SELECT max(x.o) FROM generate_series(0, c.n) i,
                   LATERAL (SELECT public.family_occurrence_date(c.id, p_date - 7 * i) AS o) x
                 WHERE x.o < p_date) AS d
    FROM c
  )
  SELECT due.d FROM due
  WHERE p_date >= DATE '2026-09-26'
    AND due.d IS NOT NULL AND due.d >= due.start_d
    AND (due.active_to IS NULL OR p_date <= due.active_to)
    AND p_date < CASE WHEN due.due_dow IS NULL THEN public.family_week_start(due.d + 7 * due.n) ELSE due.d + 7 * due.n END
    AND NOT EXISTS (SELECT 1 FROM public.family_chore_log l
                    WHERE l.chore_id = due.id AND l.occurrence_date >= due.d AND l.occurrence_date < p_date
                      AND l.status IN ('claimed','verified','excused','carried'));
$function$;
REVOKE ALL ON FUNCTION public.family_overdue_from(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_overdue_from(uuid, date) TO authenticated, service_role;

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
    AND NOT EXISTS (SELECT 1 FROM public.family_weeks f WHERE f.kid_id = l.kid_id AND f.week_start = public.family_week_start(l.occurrence_date));

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

DROP FUNCTION IF EXISTS public.family_week_board(uuid, date);
CREATE FUNCTION public.family_week_board(p_kid_id uuid, p_week_start date)
 RETURNS TABLE(chore_id uuid, title text, frequency text, part_of_day text, group_label text, due_dow smallint, pay numeric, checklist_id uuid, sort_order integer, is_burpees boolean, day date, occurrence_date date, slot smallint, status text, amount numeric, burpees_owed integer, can_act boolean, locked_by text, overdue_days integer)
 LANGUAGE sql
 STABLE
AS $function$
  WITH k AS (SELECT tracking_start FROM public.family_kids WHERE id = p_kid_id),
  t AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS today, public.family_is_parent() AS parent),
  days AS (SELECT p_week_start + i AS d FROM generate_series(0, 6) i),
  std AS (
    SELECT c.id, c.title, c.frequency, c.part_of_day, c.group_label, c.due_dow, c.pay, c.checklist_id, c.sort_order,
           c.is_burpees, c.active_from, c.active_to, d.d AS day, public.family_occurrence_date(c.id, d.d) AS occ, 1::smallint AS slot,
           NULL::int AS overdue_days
    FROM public.family_chores c CROSS JOIN days d
    WHERE c.kid_id = p_kid_id AND c.frequency IN ('daily','weekly')
      AND (c.frequency = 'daily'
           OR (c.due_dow IS NOT NULL AND c.due_dow = extract(dow FROM d.d)::int)
           OR (c.due_dow IS NULL AND extract(dow FROM d.d)::int = 5))
  ),
  -- A weekly chore's overdue days, up to today (family_overdue_from, Peter 2026-09-26).
  od AS (
    SELECT c.id, c.title, c.frequency, c.part_of_day, c.group_label, c.due_dow, c.pay, c.checklist_id, c.sort_order,
           c.is_burpees, c.active_from, c.active_to, d.d AS day, d.d AS occ, 1::smallint AS slot,
           (d.d - o.due)::int AS overdue_days
    FROM public.family_chores c CROSS JOIN days d CROSS JOIN t
    CROSS JOIN LATERAL (SELECT public.family_overdue_from(c.id, d.d) AS due) o
    WHERE c.kid_id = p_kid_id AND c.frequency = 'weekly' AND d.d <= t.today AND o.due IS NOT NULL
  ),
  ext AS (
    SELECT c.id, c.title, c.frequency, c.part_of_day, c.group_label, c.due_dow, c.pay, c.checklist_id, c.sort_order,
           c.is_burpees, c.active_from, c.active_to, l.occurrence_date AS day, l.occurrence_date AS occ, l.slot,
           NULL::int AS overdue_days
    FROM public.family_chore_log l JOIN public.family_chores c ON c.id = l.chore_id
    WHERE l.kid_id = p_kid_id AND c.frequency = 'extra' AND l.occurrence_date BETWEEN p_week_start AND p_week_start + 6
  ),
  a AS (SELECT * FROM std UNION ALL SELECT * FROM od UNION ALL SELECT * FROM ext),
  b AS (
    SELECT a.*, l.status, l.burpee_count, t.parent,
           CASE WHEN l.id IS NOT NULL THEN public.family_entry_amount(l.chore_id, l.kid_id, l.status, l.occurrence_date, l.amount) END AS amount,
           CASE WHEN a.frequency = 'daily' AND l.status IS NULL
                THEN public.family_part_locked(p_kid_id, a.occ, a.part_of_day) END AS locked_by,
           (a.frequency = 'extra' OR (a.occ >= k.tracking_start AND a.active_from <= a.occ AND (a.active_to IS NULL OR a.active_to >= a.occ)))
           AND CASE
                 WHEN a.frequency = 'weekly' AND a.due_dow IS NULL AND a.overdue_days IS NULL
                   THEN p_week_start <= t.today AND (t.parent OR t.today <= p_week_start + 6)
                 WHEN t.parent THEN a.day <= t.today
                 ELSE a.day = t.today
               END AS open_day
    FROM a CROSS JOIN k CROSS JOIN t
    LEFT JOIN public.family_chore_log l ON l.chore_id = a.id AND l.occurrence_date = a.occ AND l.slot = a.slot
    WHERE a.frequency = 'extra' OR (a.active_from <= a.occ AND (a.active_to IS NULL OR a.active_to >= a.occ))
  )
  SELECT b.id, b.title, b.frequency, b.part_of_day, b.group_label, b.due_dow, b.pay, b.checklist_id, b.sort_order,
         b.is_burpees, b.day, b.occ, b.slot, b.status, b.amount,
         CASE WHEN b.is_burpees THEN COALESCE(b.burpee_count, public.family_burpees_owed(b.id, b.occ)) END,
         b.open_day AND (b.parent OR b.locked_by IS NULL),
         b.locked_by,
         b.overdue_days
  FROM b
  ORDER BY b.sort_order, b.day, b.slot;
$function$;
REVOKE ALL ON FUNCTION public.family_week_board(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_week_board(uuid, date) TO authenticated, service_role;
