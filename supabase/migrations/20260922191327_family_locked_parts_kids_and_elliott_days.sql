-- Peter 2026-09-22: the family login gets no buttons at all in a locked part of the day
-- (no Done, no Missed). Parents keep Excuse and Missed there.
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
           OR (c.due_dow IS NULL AND extract(dow FROM d.d)::int = 6))
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

-- Writer: a locked part refuses Done and Carry for everyone, and a kid's Missed too.
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
  VALUES (v_c.agency_id, p_chore_id, v_kid, v_occ, p_status, public.family_log_amount(p_chore_id, p_status), p_note, auth.uid(), v_count)
  ON CONFLICT (chore_id, occurrence_date) DO UPDATE
    SET status = EXCLUDED.status, amount = EXCLUDED.amount,
        note = COALESCE(EXCLUDED.note, public.family_chore_log.note),
        updated_by = EXCLUDED.updated_by, burpee_count = EXCLUDED.burpee_count, updated_at = now()
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $function$;

-- Elliott: House Trash on Sunday, his other weekly chores on Friday.
UPDATE public.family_chores SET due_dow = 0 WHERE id = '0c0c81af-daf1-4022-9ba5-3d15d32170b2';
UPDATE public.family_chores SET due_dow = 5
 WHERE id IN ('518afd57-43fa-4dbb-8107-c05a390c5ed3', 'ad3120bd-e576-4bb4-b68c-1ba0637e92a8', '7090605c-fc9d-4529-a1e4-218bd7d2f4e7');
