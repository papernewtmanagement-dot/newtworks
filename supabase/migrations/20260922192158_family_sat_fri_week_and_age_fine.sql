-- Peter 2026-09-22: the family chore week runs Saturday through Friday.
-- A skipped chore is fined 10 cents per year of the kid's age (age on the chore's date).

-- 1. Week start = the Saturday on or before the date. Every family function reads this one rule.
CREATE OR REPLACE FUNCTION public.family_week_start(d date)
 RETURNS date
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT d - ((extract(dow FROM d)::int + 1) % 7);
$function$;

-- Weekly due date: due_dow is a weekday (0=Sun..6=Sat); no day means due Friday, the last day of the week.
CREATE OR REPLACE FUNCTION public.family_occurrence_date(p_chore_id uuid, p_date date)
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE WHEN c.frequency = 'weekly'
              THEN public.family_week_start(p_date) + ((COALESCE(c.due_dow, 5) + 1) % 7)
              ELSE p_date END
  FROM public.family_chores c WHERE c.id = p_chore_id;
$function$;

-- 2. Fine: the chore's own fine, else 10 cents x the kid's age on that date, else the family default.
ALTER TABLE public.family_settings ADD COLUMN IF NOT EXISTS fine_per_year numeric(6,2) NOT NULL DEFAULT 0.10;

DROP FUNCTION IF EXISTS public.family_chore_fine(uuid);
CREATE OR REPLACE FUNCTION public.family_chore_fine(p_chore_id uuid, p_on date DEFAULT ((now() AT TIME ZONE 'America/Chicago')::date))
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(c.fine,
                  CASE WHEN k.birthday IS NOT NULL
                       THEN round(COALESCE(s.fine_per_year, 0.10) * date_part('year', age(p_on, k.birthday))::int, 2) END,
                  s.missed_fine, 0)
  FROM public.family_chores c
  LEFT JOIN public.family_kids k ON k.id = c.kid_id
  LEFT JOIN public.family_settings s ON s.agency_id = c.agency_id
  WHERE c.id = p_chore_id;
$function$;
GRANT EXECUTE ON FUNCTION public.family_chore_fine(uuid, date) TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.family_log_amount(uuid, text);
CREATE OR REPLACE FUNCTION public.family_log_amount(p_chore_id uuid, p_status text, p_on date DEFAULT ((now() AT TIME ZONE 'America/Chicago')::date))
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE p_status
    WHEN 'claimed'     THEN c.pay
    WHEN 'verified'    THEN c.pay
    WHEN 'missed'      THEN -public.family_chore_fine(c.id, p_on)
    WHEN 'false_claim' THEN -round(public.family_chore_fine(c.id, p_on) * COALESCE(s.false_claim_multiplier, 2), 2)
    ELSE 0 END
  FROM public.family_chores c
  LEFT JOIN public.family_settings s ON s.agency_id = c.agency_id
  WHERE c.id = p_chore_id;
$function$;
GRANT EXECUTE ON FUNCTION public.family_log_amount(uuid, text, date) TO authenticated, service_role;

-- 3. Callers pass the chore's own date.
CREATE OR REPLACE FUNCTION public.family_sweep_missed()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE v_today date := (now() AT TIME ZONE 'America/Chicago')::date; n int;
BEGIN
  DELETE FROM public.family_chore_log l USING public.family_chores c
  WHERE c.id = l.chore_id AND c.frequency = 'extra' AND l.status = 'picked' AND l.occurrence_date < v_today;

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
    ON CONFLICT (chore_id, occurrence_date) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION public.family_set_status(p_chore_id uuid, p_occurrence_date date, p_status text, p_note text DEFAULT NULL::text, p_kid_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE v_c public.family_chores; v_occ date; v_cur text; v_cur_kid uuid; v_kid uuid;
        v_parent boolean := public.family_is_parent(); v_count int; v_row public.family_chore_log; v_lock text;
BEGIN
  SELECT * INTO v_c FROM public.family_chores WHERE id = p_chore_id;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'Chore not found.'; END IF;
  v_occ := public.family_occurrence_date(p_chore_id, p_occurrence_date);
  SELECT status, kid_id INTO v_cur, v_cur_kid FROM public.family_chore_log WHERE chore_id = p_chore_id AND occurrence_date = v_occ;
  IF v_c.frequency = 'extra' AND v_cur_kid IS NOT NULL AND p_kid_id IS NOT NULL AND v_cur_kid <> p_kid_id THEN
    RAISE EXCEPTION 'Someone else already took that one.';
  END IF;
  v_kid := COALESCE(v_c.kid_id, v_cur_kid, p_kid_id);
  IF v_kid IS NULL THEN RAISE EXCEPTION 'Pick a kid first.'; END IF;
  IF NOT v_parent THEN
    IF p_status IS NULL AND v_cur IS DISTINCT FROM 'picked' THEN RAISE EXCEPTION 'Only a parent can undo that.'; END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('claimed','missed','picked') THEN RAISE EXCEPTION 'Only a parent can do that.'; END IF;
    IF p_status = 'missed' AND v_c.frequency = 'extra' THEN RAISE EXCEPTION 'Put an extra chore back instead.'; END IF;
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
    DELETE FROM public.family_chore_log WHERE chore_id = p_chore_id AND occurrence_date = v_occ;
    RETURN jsonb_build_object('cleared', true);
  END IF;
  IF p_status = 'carried' THEN v_count := public.family_burpees_owed(p_chore_id, v_occ); END IF;
  INSERT INTO public.family_chore_log (agency_id, chore_id, kid_id, occurrence_date, status, amount, note, updated_by, burpee_count)
  VALUES (v_c.agency_id, p_chore_id, v_kid, v_occ, p_status, public.family_log_amount(p_chore_id, p_status, v_occ), p_note, auth.uid(), v_count)
  ON CONFLICT (chore_id, occurrence_date) DO UPDATE
    SET status = EXCLUDED.status, amount = EXCLUDED.amount,
        note = COALESCE(EXCLUDED.note, public.family_chore_log.note),
        updated_by = EXCLUDED.updated_by, burpee_count = EXCLUDED.burpee_count, updated_at = now()
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $function$;

-- 4. Board: no-day weekly chores sit on Friday.
CREATE OR REPLACE FUNCTION public.family_week_board(p_kid_id uuid, p_week_start date)
 RETURNS TABLE(chore_id uuid, title text, frequency text, part_of_day text, group_label text, due_dow smallint, pay numeric, checklist_id uuid, sort_order integer, is_burpees boolean, day date, occurrence_date date, status text, amount numeric, burpees_owed integer, can_act boolean, locked_by text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH k AS (SELECT tracking_start FROM public.family_kids WHERE id = p_kid_id),
  t AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS today, public.family_is_parent() AS parent),
  days AS (SELECT p_week_start + i AS d FROM generate_series(0, 6) i),
  std AS (
    SELECT c.id, c.title, c.frequency, c.part_of_day, c.group_label, c.due_dow, c.pay, c.checklist_id, c.sort_order,
           c.is_burpees, c.active_from, c.active_to, d.d AS day, public.family_occurrence_date(c.id, d.d) AS occ
    FROM public.family_chores c CROSS JOIN days d
    WHERE c.kid_id = p_kid_id AND c.frequency IN ('daily','weekly')
      AND (c.frequency = 'daily'
           OR (c.due_dow IS NOT NULL AND c.due_dow = extract(dow FROM d.d)::int)
           OR (c.due_dow IS NULL AND extract(dow FROM d.d)::int = 5))
  ),
  ext AS (
    SELECT c.id, c.title, c.frequency, c.part_of_day, c.group_label, c.due_dow, c.pay, c.checklist_id, c.sort_order,
           c.is_burpees, c.active_from, c.active_to, l.occurrence_date AS day, l.occurrence_date AS occ
    FROM public.family_chore_log l JOIN public.family_chores c ON c.id = l.chore_id
    WHERE l.kid_id = p_kid_id AND c.frequency = 'extra' AND l.occurrence_date BETWEEN p_week_start AND p_week_start + 6
  ),
  a AS (SELECT * FROM std UNION ALL SELECT * FROM ext),
  b AS (
    SELECT a.*, l.status, l.amount, l.burpee_count, t.parent,
           CASE WHEN a.frequency = 'daily' AND l.status IS NULL
                THEN public.family_part_locked(p_kid_id, a.occ, a.part_of_day) END AS locked_by,
           (a.frequency = 'extra' OR (a.occ >= k.tracking_start AND a.active_from <= a.occ AND (a.active_to IS NULL OR a.active_to >= a.occ)))
           AND CASE
                 WHEN a.frequency = 'weekly' AND a.due_dow IS NULL
                   THEN p_week_start <= t.today AND (t.parent OR t.today <= p_week_start + 6)
                 WHEN t.parent THEN a.day <= t.today
                 ELSE a.day = t.today
               END AS open_day
    FROM a CROSS JOIN k CROSS JOIN t
    LEFT JOIN public.family_chore_log l ON l.chore_id = a.id AND l.occurrence_date = a.occ
    WHERE a.frequency = 'extra' OR (a.active_from <= a.occ AND (a.active_to IS NULL OR a.active_to >= a.occ))
  )
  SELECT b.id, b.title, b.frequency, b.part_of_day, b.group_label, b.due_dow, b.pay, b.checklist_id, b.sort_order,
         b.is_burpees, b.day, b.occ, b.status, b.amount,
         CASE WHEN b.is_burpees THEN COALESCE(b.burpee_count, public.family_burpees_owed(b.id, b.occ)) END,
         b.open_day AND (b.parent OR b.locked_by IS NULL),
         b.locked_by
  FROM b
  ORDER BY b.sort_order, b.day;
$function$;

-- 5. Close-out message follows the new week.
CREATE OR REPLACE FUNCTION public.family_close_week(p_kid_id uuid, p_week_start date, p_solved_by_parent boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE v_today date := (now() AT TIME ZONE 'America/Chicago')::date; v_first date; v_agency uuid;
BEGIN
  IF p_week_start <> public.family_week_start(p_week_start) THEN RAISE EXCEPTION 'A week starts on Saturday.'; END IF;
  IF p_week_start + 6 >= v_today THEN RAISE EXCEPTION 'This week is not over yet.'; END IF;
  IF p_solved_by_parent AND NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can solve it for them.'; END IF;
  SELECT agency_id, public.family_week_start(tracking_start) INTO v_agency, v_first FROM public.family_kids WHERE id = p_kid_id;
  IF v_agency IS NULL THEN RAISE EXCEPTION 'Kid not found.'; END IF;
  IF EXISTS (SELECT 1 FROM generate_series(v_first, p_week_start - 7, interval '7 days') w
             WHERE NOT EXISTS (SELECT 1 FROM public.family_weeks f WHERE f.kid_id = p_kid_id AND f.week_start = w::date)) THEN
    RAISE EXCEPTION 'Close out the earlier week first.';
  END IF;
  PERFORM public.family_sweep_missed();
  INSERT INTO public.family_weeks (agency_id, kid_id, week_start, closed_by, solved_by_parent, register)
  VALUES (v_agency, p_kid_id, p_week_start, auth.uid(), p_solved_by_parent, public.family_week_register(p_kid_id, p_week_start))
  ON CONFLICT (kid_id, week_start) DO NOTHING;
  RETURN (SELECT to_jsonb(m) FROM public.family_kid_money(p_kid_id, public.family_week_start(v_today)) m);
END $function$;

-- 6. Redo the amount on fines already written.
UPDATE public.family_chore_log l
   SET amount = public.family_log_amount(l.chore_id, l.status, l.occurrence_date), updated_at = now()
 WHERE l.status IN ('missed','false_claim');
