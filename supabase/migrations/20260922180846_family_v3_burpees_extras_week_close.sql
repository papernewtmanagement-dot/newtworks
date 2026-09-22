-- Family module v3 (2026-09-22): names + animals + birthdays + Henry; title case; $5 flat fine;
-- burpees (10 x age, carry forward); extra chores (paid on completion, recurring); week close-out
-- (standard chore pay posts at close, 10% tithe + 10% invest set aside from every income);
-- point-by-point instructions for every chore; course pages flattened under an Overview.

-- Kids -----------------------------------------------------------------
ALTER TABLE public.family_kids ADD COLUMN IF NOT EXISTS birthday date;
ALTER TABLE public.family_kids ADD COLUMN IF NOT EXISTS animal text;
ALTER TABLE public.family_kids ADD COLUMN IF NOT EXISTS favorite_animal text;
UPDATE public.family_kids SET name = 'Elliott' WHERE name = 'Goose';
UPDATE public.family_kids SET name = 'Olive'   WHERE name = 'Duck';
UPDATE public.family_kids k SET birthday = v.b, animal = v.a, favorite_animal = v.f
FROM (VALUES ('Becca', DATE '2011-02-03', 'woodpecker', 'lizard'),
             ('Bella', DATE '2014-08-26', 'puffin', 'axolotl'),
             ('Elliott', DATE '2018-08-31', 'goose', 'turtle'),
             ('Olive', DATE '2021-09-07', 'duck', 'lemur')) v(n, b, a, f)
WHERE k.name = v.n;
INSERT INTO public.family_kids (agency_id, name, sort_order, tracking_start, birthday, animal, favorite_animal)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Henry', 5, DATE '2026-09-23', DATE '2025-07-18', 'rooster', 'sloth'
WHERE NOT EXISTS (SELECT 1 FROM public.family_kids WHERE name = 'Henry');

-- Flat fine for a chore not done ------------------------------------------
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='family_settings' AND column_name='min_fine') THEN
    ALTER TABLE public.family_settings RENAME COLUMN min_fine TO missed_fine;
  END IF;
END $$;
ALTER TABLE public.family_settings ALTER COLUMN missed_fine SET DEFAULT 5.00;
UPDATE public.family_settings SET missed_fine = 5.00, updated_at = now();

-- Chores: extras, burpees, any-time ------------------------------------
ALTER TABLE public.family_chores ALTER COLUMN kid_id DROP NOT NULL;
ALTER TABLE public.family_chores DROP CONSTRAINT IF EXISTS family_chores_frequency_check;
ALTER TABLE public.family_chores ADD CONSTRAINT family_chores_frequency_check CHECK (frequency IN ('daily','weekly','extra'));
ALTER TABLE public.family_chores DROP CONSTRAINT IF EXISTS family_chores_part_of_day_check;
ALTER TABLE public.family_chores ADD CONSTRAINT family_chores_part_of_day_check CHECK (part_of_day IN ('morning','afternoon','evening','anytime'));
ALTER TABLE public.family_chores DROP CONSTRAINT IF EXISTS family_chores_kid_needed;
ALTER TABLE public.family_chores ADD CONSTRAINT family_chores_kid_needed CHECK (frequency = 'extra' OR kid_id IS NOT NULL);
ALTER TABLE public.family_chores ADD COLUMN IF NOT EXISTS is_burpees boolean NOT NULL DEFAULT false;
ALTER TABLE public.family_chores ADD COLUMN IF NOT EXISTS repeat_days int CHECK (repeat_days IS NULL OR repeat_days > 0);
COMMENT ON COLUMN public.family_chores.repeat_days IS 'Extra chores only. Comes back this many days after it was last done. NULL = one time.';

ALTER TABLE public.family_chore_log DROP CONSTRAINT IF EXISTS family_chore_log_status_check;
ALTER TABLE public.family_chore_log ADD CONSTRAINT family_chore_log_status_check
  CHECK (status IN ('claimed','verified','missed','false_claim','excused','carried','picked'));
ALTER TABLE public.family_chore_log ADD COLUMN IF NOT EXISTS burpee_count int;

-- Title case
UPDATE public.family_chores c SET title = v.t
FROM (VALUES ('DRINK WATER','Drink Water'), ('BURPEES','Burpees'), ('REVIEW VERSES','Review Verses'),
             ('WATER BOTTLE 1','Water Bottle 1'), ('WATER BOTTLE 2','Water Bottle 2'), ('Pick up Poop','Pick Up Poop'),
             ('Feed Dogs (give vitamins)','Feed Dogs (Give Vitamins)'), ('Mop all Floors','Mop All Floors')) v(o, t)
WHERE c.title = v.o;
UPDATE public.family_chores SET group_label = 'Office' WHERE group_label = 'OFFICE';
UPDATE public.family_chores SET is_burpees = true WHERE title = 'Burpees';

-- Henry
INSERT INTO public.family_chores (agency_id, kid_id, title, frequency, part_of_day, pay, fine, sort_order, active_from)
SELECT k.agency_id, k.id, 'Be Cute', 'daily', 'anytime', 0, 0, 1, DATE '2026-09-23'
FROM public.family_kids k WHERE k.name = 'Henry'
  AND NOT EXISTS (SELECT 1 FROM public.family_chores c WHERE c.kid_id = k.id);

-- Week close-outs -------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.family_weeks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  kid_id uuid NOT NULL REFERENCES public.family_kids(id) ON DELETE CASCADE,
  week_start date NOT NULL,
  closed_at timestamptz NOT NULL DEFAULT now(),
  closed_by uuid,
  solved_by_parent boolean NOT NULL DEFAULT false,
  register jsonb,
  UNIQUE (kid_id, week_start)
);
ALTER TABLE public.family_weeks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS family_weeks_parents_all ON public.family_weeks;
DROP POLICY IF EXISTS family_weeks_family_read ON public.family_weeks;
DROP POLICY IF EXISTS family_weeks_family_insert ON public.family_weeks;
CREATE POLICY family_weeks_parents_all ON public.family_weeks FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));
CREATE POLICY family_weeks_family_read ON public.family_weeks FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.auth_is_family()));
CREATE POLICY family_weeks_family_insert ON public.family_weeks FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.auth_is_family()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.family_weeks TO authenticated;

-- Starting balances sit before the first tracked week so they are the first week's starting point.
UPDATE public.family_ledger SET entry_date = DATE '2026-09-19' WHERE kind = 'opening_balance';

-- Money rules -----------------------------------------------------------
-- Fine for one chore: its own fine if set, else the family's flat fine.
CREATE OR REPLACE FUNCTION public.family_chore_fine(p_chore_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE(c.fine, s.missed_fine, 5.00)
  FROM public.family_chores c
  LEFT JOIN public.family_settings s ON s.agency_id = c.agency_id
  WHERE c.id = p_chore_id;
$$;

-- 10% (or any percent) of an amount, to the nearest cent. The only rounding rule for set-asides.
CREATE OR REPLACE FUNCTION public.family_set_aside(p_amount numeric, p_pct numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT round(p_amount * p_pct / 100, 2); $$;

-- Burpees owed in one slot: 10 x age (none under 2) plus whatever the slot before carried in.
-- Morning takes from the day before's afternoon; afternoon takes from the same day's morning.
CREATE OR REPLACE FUNCTION public.family_burpees_owed(p_chore_id uuid, p_date date)
RETURNS int LANGUAGE sql STABLE AS $$
  WITH c AS (SELECT id, kid_id, part_of_day FROM public.family_chores WHERE id = p_chore_id AND is_burpees),
  k AS (SELECT birthday FROM public.family_kids WHERE id = (SELECT kid_id FROM c)),
  base AS (
    SELECT CASE WHEN k.birthday IS NULL THEN 0
                WHEN date_part('year', age(p_date, k.birthday)) >= 2 THEN 10 * date_part('year', age(p_date, k.birthday))::int
                ELSE 0 END AS n
    FROM k
  ),
  prev AS (
    SELECT p.id AS prev_id, CASE WHEN c.part_of_day = 'afternoon' THEN p_date ELSE p_date - 1 END AS prev_date
    FROM c JOIN public.family_chores p ON p.kid_id = c.kid_id AND p.is_burpees AND p.id <> c.id
     AND p.part_of_day = CASE WHEN c.part_of_day = 'afternoon' THEN 'morning' ELSE 'afternoon' END
    LIMIT 1
  )
  SELECT COALESCE((SELECT n FROM base), 0)
       + COALESCE((SELECT l.burpee_count FROM prev JOIN public.family_chore_log l
                   ON l.chore_id = prev.prev_id AND l.occurrence_date = prev.prev_date AND l.status = 'carried'), 0);
$$;

-- Only writer of chore outcomes. Kids (family login) may only mark Done, carry burpees, pick an
-- extra chore, or put back an extra they picked. Parents can do anything, including excuse.
DROP FUNCTION IF EXISTS public.family_set_status(uuid, date, text, text);
CREATE OR REPLACE FUNCTION public.family_set_status(p_chore_id uuid, p_occurrence_date date, p_status text,
                                                    p_note text DEFAULT NULL, p_kid_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE v_c public.family_chores; v_occ date; v_cur text; v_cur_kid uuid; v_kid uuid;
        v_parent boolean := public.family_is_parent(); v_count int; v_row public.family_chore_log;
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
    IF p_status IS NOT NULL AND p_status NOT IN ('claimed','carried','picked') THEN RAISE EXCEPTION 'Only a parent can do that.'; END IF;
    IF v_cur IN ('missed','false_claim','excused','verified') THEN RAISE EXCEPTION 'Only a parent can change that.'; END IF;
  END IF;
  IF p_status = 'carried' AND NOT v_c.is_burpees THEN RAISE EXCEPTION 'Only burpees can be carried.'; END IF;
  IF p_status = 'picked' AND v_c.frequency <> 'extra' THEN RAISE EXCEPTION 'Only extra chores can be picked.'; END IF;
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
END $$;

-- End of day: every standard chore still open is missed and fined. Extra chores that were
-- picked but not done go back on the list, no fine. Carried burpees are not fined.
CREATE OR REPLACE FUNCTION public.family_sweep_missed()
RETURNS int LANGUAGE plpgsql SECURITY INVOKER AS $$
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
    SELECT o.agency_id, o.chore_id, o.kid_id, o.occurrence_date, 'missed', public.family_log_amount(o.chore_id, 'missed')
    FROM occ o
    WHERE o.occurrence_date >= o.start_d AND o.occurrence_date < v_today
      AND (o.active_to IS NULL OR o.occurrence_date <= o.active_to)
    ON CONFLICT (chore_id, occurrence_date) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;
  RETURN n;
END $$;

-- Every money event in one kid's week, in order. The only place that decides what counts as
-- income and what gets set aside. Fines are one line per day. Extra chores are paid when done.
-- The week's standard chores are one line, paid at close-out.
CREATE OR REPLACE FUNCTION public.family_week_events(p_kid_id uuid, p_week_start date)
RETURNS TABLE (seq int, event_date date, kind text, label text, bucket text, amount numeric,
               is_income boolean, tithe numeric, invest numeric)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
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
                     WHEN 'tithe_given' THEN 'Tithe given' WHEN 'invested' THEN 'Invested' ELSE kind END
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
$$;

-- One kid's money through the end of a given week. Closed weeks: everything, with set-asides moved.
-- Open weeks: fines, extra pay and parent entries count now; standard chore pay waits for close-out.
CREATE OR REPLACE FUNCTION public.family_kid_money(p_kid_id uuid, p_through_week date)
RETURNS TABLE (spend numeric, tithe numeric, invest numeric, pending numeric)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
  WITH k AS (SELECT tracking_start FROM public.family_kids WHERE id = p_kid_id),
  weeks AS (
    SELECT w::date AS ws FROM k,
    generate_series(public.family_week_start(k.tracking_start), p_through_week, interval '7 days') w
  ),
  ev AS (
    SELECT (fw.id IS NOT NULL) AS is_closed, e.*
    FROM weeks
    LEFT JOIN public.family_weeks fw ON fw.kid_id = p_kid_id AND fw.week_start = weeks.ws
    CROSS JOIN LATERAL public.family_week_events(p_kid_id, weeks.ws) e
  ),
  opening AS (SELECT COALESCE(sum(amount), 0) AS amt FROM public.family_ledger WHERE kid_id = p_kid_id AND kind = 'opening_balance')
  SELECT (SELECT amt FROM opening)
           + COALESCE(sum(ev.amount) FILTER (WHERE ev.bucket = 'spend' AND (ev.is_closed OR ev.kind <> 'chore_pay')), 0)
           - COALESCE(sum(ev.tithe + ev.invest) FILTER (WHERE ev.is_closed), 0),
         COALESCE(sum(ev.amount) FILTER (WHERE ev.bucket = 'tithe'), 0) + COALESCE(sum(ev.tithe) FILTER (WHERE ev.is_closed), 0),
         COALESCE(sum(ev.amount) FILTER (WHERE ev.bucket = 'invest'), 0) + COALESCE(sum(ev.invest) FILTER (WHERE ev.is_closed), 0),
         COALESCE(sum(ev.amount) FILTER (WHERE ev.kind = 'chore_pay' AND NOT ev.is_closed), 0)
  FROM ev;
$$;

DROP FUNCTION IF EXISTS public.family_balances(date);
CREATE OR REPLACE FUNCTION public.family_balances(p_week_start date DEFAULT NULL)
RETURNS TABLE (kid_id uuid, name text, spend numeric, tithe numeric, invest numeric, pending_pay numeric,
               week_earned numeric, week_fines numeric, week_possible numeric, next_close date)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
  WITH t AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS today),
  wk AS (SELECT COALESCE(p_week_start, public.family_week_start(t.today)) AS ws FROM t),
  tw AS (
    SELECT l.kid_id, sum(l.amount) FILTER (WHERE l.amount > 0) AS earned, sum(l.amount) FILTER (WHERE l.amount < 0) AS fines
    FROM public.family_chore_log l, wk WHERE l.occurrence_date BETWEEN wk.ws AND wk.ws + 6 GROUP BY 1
  ),
  possible AS (
    SELECT c.kid_id, sum(c.pay * CASE WHEN c.frequency = 'daily' THEN 7 ELSE 1 END) AS amt
    FROM public.family_chores c, wk
    WHERE c.frequency IN ('daily','weekly') AND c.active_from <= wk.ws + 6 AND (c.active_to IS NULL OR c.active_to >= wk.ws)
    GROUP BY 1
  )
  SELECT k.id, k.name, m.spend, m.tithe, m.invest, m.pending,
         COALESCE(tw.earned, 0), COALESCE(tw.fines, 0), COALESCE(p.amt, 0),
         (SELECT min(w::date) FROM generate_series(public.family_week_start(k.tracking_start), public.family_week_start(t.today) - 7, interval '7 days') w
          WHERE NOT EXISTS (SELECT 1 FROM public.family_weeks f WHERE f.kid_id = k.id AND f.week_start = w::date))
  FROM public.family_kids k
  CROSS JOIN t
  CROSS JOIN LATERAL public.family_kid_money(k.id, public.family_week_start(t.today)) m
  LEFT JOIN tw ON tw.kid_id = k.id
  LEFT JOIN possible p ON p.kid_id = k.id
  WHERE k.is_active
  ORDER BY k.sort_order;
$$;

-- Everything the close-out screen needs: where the money started and each event in order.
CREATE OR REPLACE FUNCTION public.family_week_register(p_kid_id uuid, p_week_start date)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER AS $$
  SELECT jsonb_build_object(
    'kid_id', k.id, 'week_start', p_week_start, 'tithe_pct', k.tithe_pct, 'invest_pct', k.invest_pct,
    'closed', EXISTS (SELECT 1 FROM public.family_weeks f WHERE f.kid_id = k.id AND f.week_start = p_week_start),
    'start', (SELECT to_jsonb(m) FROM public.family_kid_money(k.id, p_week_start - 7) m),
    'events', COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.seq) FROM public.family_week_events(k.id, p_week_start) e), '[]'::jsonb))
  FROM public.family_kids k WHERE k.id = p_kid_id;
$$;

-- Closes a finished week: posts the week's chore pay and moves the set-asides. Weeks close in order.
CREATE OR REPLACE FUNCTION public.family_close_week(p_kid_id uuid, p_week_start date, p_solved_by_parent boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE v_today date := (now() AT TIME ZONE 'America/Chicago')::date; v_first date; v_agency uuid;
BEGIN
  IF p_week_start <> public.family_week_start(p_week_start) THEN RAISE EXCEPTION 'A week starts on Sunday.'; END IF;
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
END $$;

-- The week grid: one row per chore per day it is due, plus extra chores this kid picked.
-- can_act: kids act on today only; parents on today or any earlier tracked day.
CREATE OR REPLACE FUNCTION public.family_week_board(p_kid_id uuid, p_week_start date)
RETURNS TABLE (chore_id uuid, title text, frequency text, part_of_day text, group_label text, due_dow smallint,
               pay numeric, checklist_id uuid, sort_order int, is_burpees boolean,
               day date, occurrence_date date, status text, amount numeric, burpees_owed int, can_act boolean)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
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
             END
  FROM a CROSS JOIN k CROSS JOIN t
  LEFT JOIN public.family_chore_log l ON l.chore_id = a.id AND l.occurrence_date = a.occ
  WHERE a.frequency = 'extra' OR (a.active_from <= a.occ AND (a.active_to IS NULL OR a.active_to >= a.occ))
  ORDER BY a.sort_order, a.day;
$$;

-- Extra chores anyone can pick on a day: not taken that day, and not done too recently to come back.
CREATE OR REPLACE FUNCTION public.family_extras_available(p_date date)
RETURNS TABLE (chore_id uuid, title text, pay numeric, checklist_id uuid, repeat_days int)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
  SELECT c.id, c.title, c.pay, c.checklist_id, c.repeat_days
  FROM public.family_chores c
  WHERE c.frequency = 'extra' AND c.active_from <= p_date AND (c.active_to IS NULL OR c.active_to >= p_date)
    AND NOT EXISTS (SELECT 1 FROM public.family_chore_log l WHERE l.chore_id = c.id AND l.occurrence_date = p_date)
    AND NOT EXISTS (SELECT 1 FROM public.family_chore_log l WHERE l.chore_id = c.id AND l.status IN ('claimed','verified')
                      AND (c.repeat_days IS NULL OR l.occurrence_date > p_date - c.repeat_days))
  ORDER BY c.title;
$$;

GRANT EXECUTE ON FUNCTION public.family_set_aside(numeric, numeric), public.family_burpees_owed(uuid, date),
  public.family_set_status(uuid, date, text, text, uuid), public.family_week_events(uuid, date),
  public.family_kid_money(uuid, date), public.family_balances(date), public.family_week_register(uuid, date),
  public.family_close_week(uuid, date, boolean), public.family_week_board(uuid, date),
  public.family_extras_available(date) TO authenticated;
