-- Peter 2026-09-22: some extra chores (babysitting) can be done any number of times a day.
-- repeat_days = 0 means "any number of times a day". Each time is its own log row, numbered by slot.
-- Also: an extra chore is never fined. Unchecking it clears it.

ALTER TABLE public.family_chores DROP CONSTRAINT IF EXISTS family_chores_repeat_days_check;
ALTER TABLE public.family_chores ADD CONSTRAINT family_chores_repeat_days_check CHECK (repeat_days IS NULL OR repeat_days >= 0);

ALTER TABLE public.family_chore_log ADD COLUMN IF NOT EXISTS slot smallint NOT NULL DEFAULT 1 CHECK (slot >= 1);
ALTER TABLE public.family_chore_log DROP CONSTRAINT IF EXISTS family_chore_log_chore_id_occurrence_date_key;
ALTER TABLE public.family_chore_log DROP CONSTRAINT IF EXISTS family_chore_log_chore_date_slot_key;
ALTER TABLE public.family_chore_log ADD CONSTRAINT family_chore_log_chore_date_slot_key UNIQUE (chore_id, occurrence_date, slot);

-- Babysitting is the first multi-use extra.
UPDATE public.family_chores SET repeat_days = 0 WHERE id = '5348497a-a1f6-40a0-8c37-8985c3897121';

-- The ✗ Peter tapped on Becca's babysitting meant "uncheck"; it wrote a $10 fine instead. Remove it.
DELETE FROM public.family_chore_log WHERE id = '10d205b0-4a2f-4ad2-b508-0a39d7ec5164';

CREATE OR REPLACE FUNCTION public.family_extras_available(p_date date)
 RETURNS TABLE(chore_id uuid, title text, pay numeric, checklist_id uuid, repeat_days integer)
 LANGUAGE sql
 STABLE
AS $function$
  SELECT c.id, c.title, c.pay, c.checklist_id, c.repeat_days
  FROM public.family_chores c
  WHERE c.frequency = 'extra' AND c.active_from <= p_date AND (c.active_to IS NULL OR c.active_to >= p_date)
    AND (c.repeat_days = 0 OR (
          NOT EXISTS (SELECT 1 FROM public.family_chore_log l WHERE l.chore_id = c.id AND l.occurrence_date = p_date)
      AND NOT EXISTS (SELECT 1 FROM public.family_chore_log l WHERE l.chore_id = c.id AND l.status IN ('claimed','verified')
                        AND (c.repeat_days IS NULL OR l.occurrence_date > p_date - c.repeat_days))))
  ORDER BY c.title;
$function$;

DROP FUNCTION IF EXISTS public.family_set_status(uuid, date, text, text, uuid);
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
GRANT EXECUTE ON FUNCTION public.family_set_status(uuid, date, text, text, uuid, smallint) TO authenticated, service_role;

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
    ON CONFLICT (chore_id, occurrence_date, slot) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;
  RETURN n;
END $function$;

DROP FUNCTION IF EXISTS public.family_week_board(uuid, date);
CREATE FUNCTION public.family_week_board(p_kid_id uuid, p_week_start date)
 RETURNS TABLE(chore_id uuid, title text, frequency text, part_of_day text, group_label text, due_dow smallint, pay numeric, checklist_id uuid, sort_order integer, is_burpees boolean, day date, occurrence_date date, slot smallint, status text, amount numeric, burpees_owed integer, can_act boolean, locked_by text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH k AS (SELECT tracking_start FROM public.family_kids WHERE id = p_kid_id),
  t AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS today, public.family_is_parent() AS parent),
  days AS (SELECT p_week_start + i AS d FROM generate_series(0, 6) i),
  std AS (
    SELECT c.id, c.title, c.frequency, c.part_of_day, c.group_label, c.due_dow, c.pay, c.checklist_id, c.sort_order,
           c.is_burpees, c.active_from, c.active_to, d.d AS day, public.family_occurrence_date(c.id, d.d) AS occ, 1::smallint AS slot
    FROM public.family_chores c CROSS JOIN days d
    WHERE c.kid_id = p_kid_id AND c.frequency IN ('daily','weekly')
      AND (c.frequency = 'daily'
           OR (c.due_dow IS NOT NULL AND c.due_dow = extract(dow FROM d.d)::int)
           OR (c.due_dow IS NULL AND extract(dow FROM d.d)::int = 5))
  ),
  ext AS (
    SELECT c.id, c.title, c.frequency, c.part_of_day, c.group_label, c.due_dow, c.pay, c.checklist_id, c.sort_order,
           c.is_burpees, c.active_from, c.active_to, l.occurrence_date AS day, l.occurrence_date AS occ, l.slot
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
    LEFT JOIN public.family_chore_log l ON l.chore_id = a.id AND l.occurrence_date = a.occ AND l.slot = a.slot
    WHERE a.frequency = 'extra' OR (a.active_from <= a.occ AND (a.active_to IS NULL OR a.active_to >= a.occ))
  )
  SELECT b.id, b.title, b.frequency, b.part_of_day, b.group_label, b.due_dow, b.pay, b.checklist_id, b.sort_order,
         b.is_burpees, b.day, b.occ, b.slot, b.status, b.amount,
         CASE WHEN b.is_burpees THEN COALESCE(b.burpee_count, public.family_burpees_owed(b.id, b.occ)) END,
         b.open_day AND (b.parent OR b.locked_by IS NULL),
         b.locked_by
  FROM b
  ORDER BY b.sort_order, b.day, b.slot;
$function$;
GRANT EXECUTE ON FUNCTION public.family_week_board(uuid, date) TO authenticated, service_role;
