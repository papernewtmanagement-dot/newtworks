-- Peter 2026-09-22: fines page, kids can mark not done, only parents carry, pay $5/hr.

-- 1. Fine catalog. Parents create fines; applying one writes a family_ledger row (kind 'fine'),
--    so it flows through family_week_events like every other money event.
CREATE TABLE IF NOT EXISTS public.family_fine_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365' REFERENCES public.agency(id),
  name text NOT NULL,
  amount numeric(8,2) NOT NULL CHECK (amount > 0),
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.family_fine_types ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS family_fine_types_family_read ON public.family_fine_types;
CREATE POLICY family_fine_types_family_read ON public.family_fine_types FOR SELECT
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT auth_is_family()));
DROP POLICY IF EXISTS family_fine_types_parents_all ON public.family_fine_types;
CREATE POLICY family_fine_types_parents_all ON public.family_fine_types FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.family_fine_types TO authenticated;

INSERT INTO public.family_fine_types (name, amount, sort_order)
SELECT v.n, v.a, v.s FROM (VALUES
  ('Lying', 50.00, 1),
  ('Dirty dish', 2.00, 2),
  ('Not checking in about school before an exam', 50.00, 3)
) v(n, a, s)
WHERE NOT EXISTS (SELECT 1 FROM public.family_fine_types f WHERE f.name = v.n);

ALTER TABLE public.family_ledger ADD COLUMN IF NOT EXISTS fine_type_id uuid REFERENCES public.family_fine_types(id) ON DELETE SET NULL;
ALTER TABLE public.family_ledger DROP CONSTRAINT IF EXISTS family_ledger_kind_check;
ALTER TABLE public.family_ledger ADD CONSTRAINT family_ledger_kind_check
  CHECK (kind = ANY (ARRAY['payout','tithe_given','invested','bonus','adjustment','opening_balance','fine']));
ALTER TABLE public.family_ledger DROP CONSTRAINT IF EXISTS family_ledger_fine_negative;
ALTER TABLE public.family_ledger ADD CONSTRAINT family_ledger_fine_negative CHECK (kind <> 'fine' OR (amount < 0 AND bucket = 'spend'));

-- Only parents apply fines.
DROP POLICY IF EXISTS family_ledger_family_insert ON public.family_ledger;
CREATE POLICY family_ledger_family_insert ON public.family_ledger FOR INSERT
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT auth_is_family()) AND kind <> 'fine');

-- Register label for applied fines.
CREATE OR REPLACE FUNCTION public.family_week_events(p_kid_id uuid, p_week_start date)
 RETURNS TABLE(seq integer, event_date date, kind text, label text, bucket text, amount numeric, is_income boolean, tithe numeric, invest numeric)
 LANGUAGE sql
 STABLE
AS $function$
  WITH k AS (SELECT tithe_pct, invest_pct FROM public.family_kids WHERE id = p_kid_id),
  logs AS (
    SELECT l.occurrence_date AS d, l.amount, c.frequency, c.title
    FROM public.family_chore_log l JOIN public.family_chores c ON c.id = l.chore_id
    WHERE l.kid_id = p_kid_id AND l.occurrence_date BETWEEN p_week_start AND p_week_start + 6
  ),
  ev AS (
    SELECT d AS event_date, 1 AS ord, 'fines' AS kind,
           trim(to_char(d, 'Day')) || ': ' || count(*) || CASE WHEN count(*) = 1 THEN ' fine' ELSE ' fines' END AS label,
           'spend' AS bucket, sum(amount) AS amount, false AS is_income
    FROM logs WHERE amount < 0 GROUP BY d
    UNION ALL
    SELECT d, 2, 'extra', title, 'spend', amount, true FROM logs WHERE frequency = 'extra' AND amount > 0
    UNION ALL
    SELECT entry_date, 3, kind,
           CASE kind WHEN 'payout' THEN 'Cash paid out' WHEN 'bonus' THEN 'Bonus' WHEN 'adjustment' THEN 'Adjustment'
                     WHEN 'tithe_given' THEN 'Tithe given' WHEN 'invested' THEN 'Invested' WHEN 'fine' THEN 'Fine' ELSE kind END
             || COALESCE(' · ' || note, ''),
           bucket, amount, (kind = 'bonus')
    FROM public.family_ledger
    WHERE kid_id = p_kid_id AND kind <> 'opening_balance' AND entry_date BETWEEN p_week_start AND p_week_start + 6
    UNION ALL
    SELECT p_week_start + 6, 4, 'chore_pay', 'Chores this week', 'spend', sum(amount), true
    FROM logs WHERE frequency <> 'extra' AND amount > 0 HAVING sum(amount) > 0
  )
  SELECT (row_number() OVER (ORDER BY ev.event_date, ev.ord, ev.label))::int, ev.event_date, ev.kind, ev.label,
         ev.bucket, ev.amount, ev.is_income,
         CASE WHEN ev.is_income THEN public.family_set_aside(ev.amount, k.tithe_pct) ELSE 0 END,
         CASE WHEN ev.is_income THEN public.family_set_aside(ev.amount, k.invest_pct) ELSE 0 END
  FROM ev CROSS JOIN k
  ORDER BY 1;
$function$;

-- 2. Board: a locked part no longer blocks a kid's "Not done". can_act = the day is open;
--    locked_by tells the screen to hide Done. The writer still refuses Done in a locked part.
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
  a AS (SELECT * FROM std UNION ALL SELECT * FROM ext)
  SELECT a.id, a.title, a.frequency, a.part_of_day, a.group_label, a.due_dow, a.pay, a.checklist_id, a.sort_order,
         a.is_burpees, a.day, a.occ, l.status, l.amount,
         CASE WHEN a.is_burpees THEN COALESCE(l.burpee_count, public.family_burpees_owed(a.id, a.occ)) END,
         (a.frequency = 'extra' OR (a.occ >= k.tracking_start AND a.active_from <= a.occ AND (a.active_to IS NULL OR a.active_to >= a.occ)))
         AND CASE
               WHEN a.frequency = 'weekly' AND a.due_dow IS NULL
                 THEN p_week_start <= t.today AND (t.parent OR t.today <= p_week_start + 6)
               WHEN t.parent THEN a.day <= t.today
               ELSE a.day = t.today
             END,
         CASE WHEN a.frequency = 'daily' AND l.status IS NULL
              THEN public.family_part_locked(p_kid_id, a.occ, a.part_of_day) END
  FROM a CROSS JOIN k CROSS JOIN t
  LEFT JOIN public.family_chore_log l ON l.chore_id = a.id AND l.occurrence_date = a.occ
  WHERE a.frequency = 'extra' OR (a.active_from <= a.occ AND (a.active_to IS NULL OR a.active_to >= a.occ))
  ORDER BY a.sort_order, a.day;
$function$;

-- 3. Writer: kids may mark Done or Not done (missed); only parents Carry.
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
  IF p_status IN ('claimed','carried') AND v_c.frequency = 'daily' AND v_cur IS NULL THEN
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

-- 4. Pay rate $5/hr; every paid chore re-priced from its minutes by the one pay rule.
UPDATE public.family_settings SET hourly_rate = 5.00, updated_at = now();
UPDATE public.family_chores SET pay = public.family_minutes_pay(est_minutes, agency_id)
WHERE est_minutes IS NOT NULL AND pay > 0;
