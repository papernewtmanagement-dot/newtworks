-- Family module v2 (2026-09-22):
--  * family login role: sees only Family + Course; locked out of every agency table
--  * weekly chores get a set day (due_dow) read from the grayed-out cells on Marie's chart
--  * one board function feeds the screen; excuse is parents-only
--  * removes the Sep 21 misses my sweep wrote for a day nobody could log; tracking starts Sep 23
--  * starting balances; financial literacy course moved out of Admin into its own manual

-- Roles ---------------------------------------------------------------
DO $$ DECLARE c text; BEGIN
  SELECT conname INTO c FROM pg_constraint
  WHERE conrelid = 'public.users'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) ILIKE '%role%owner%';
  IF c IS NOT NULL THEN EXECUTE format('ALTER TABLE public.users DROP CONSTRAINT %I', c); END IF;
END $$;
ALTER TABLE public.users ADD CONSTRAINT users_role_check
  CHECK (role = ANY (ARRAY['owner','manager','staff','readonly','accountant','family']));

CREATE OR REPLACE FUNCTION public.auth_is_family()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.users WHERE auth_user_id = auth.uid() AND role = 'family');
$$;
CREATE OR REPLACE FUNCTION public.family_is_parent()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.users WHERE auth_user_id = auth.uid() AND role IN ('owner','manager'));
$$;
GRANT EXECUTE ON FUNCTION public.auth_is_family(), public.family_is_parent() TO authenticated;

-- Family table access: parents full; family login reads all, writes chore log + ledger entries only.
DO $pol$
DECLARE t text;
  agency_ok text := $q$agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid$q$;
BEGIN
  FOREACH t IN ARRAY ARRAY['family_settings','family_kids','family_checklists','family_chores','family_chore_log','family_ledger'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_parents_all', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_family_read', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (%s AND (SELECT public.family_is_parent())) WITH CHECK (%s AND (SELECT public.family_is_parent()))', t || '_parents_all', t, agency_ok, agency_ok);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s AND (SELECT public.auth_is_family()))', t || '_family_read', t, agency_ok);
  END LOOP;
  DROP POLICY IF EXISTS family_chore_log_family_insert ON public.family_chore_log;
  DROP POLICY IF EXISTS family_chore_log_family_update ON public.family_chore_log;
  DROP POLICY IF EXISTS family_chore_log_family_delete ON public.family_chore_log;
  DROP POLICY IF EXISTS family_ledger_family_insert ON public.family_ledger;
  EXECUTE format('CREATE POLICY family_chore_log_family_insert ON public.family_chore_log FOR INSERT TO authenticated WITH CHECK (%s AND (SELECT public.auth_is_family()))', agency_ok);
  EXECUTE format('CREATE POLICY family_chore_log_family_update ON public.family_chore_log FOR UPDATE TO authenticated USING (%s AND (SELECT public.auth_is_family())) WITH CHECK (%s AND (SELECT public.auth_is_family()))', agency_ok, agency_ok);
  EXECUTE format('CREATE POLICY family_chore_log_family_delete ON public.family_chore_log FOR DELETE TO authenticated USING (%s AND (SELECT public.auth_is_family()))', agency_ok);
  EXECUTE format('CREATE POLICY family_ledger_family_insert ON public.family_ledger FOR INSERT TO authenticated WITH CHECK (%s AND (SELECT public.auth_is_family()))', agency_ok);
END $pol$;

-- Lock the family login out of every agency table. Restrictive = must pass on top of the
-- existing rules, so staff access is unchanged. New tables do not get this automatically.
DO $lock$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND c.relrowsecurity
      AND c.relname NOT LIKE 'family\_%' AND c.relname NOT IN ('users','agency','manuals')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS zz_block_family_login ON public.%I', r.relname);
    EXECUTE format('CREATE POLICY zz_block_family_login ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (NOT (SELECT public.auth_is_family())) WITH CHECK (NOT (SELECT public.auth_is_family()))', r.relname);
  END LOOP;
END $lock$;

-- Manuals: family login reads the course only.
DROP POLICY IF EXISTS zz_block_family_login ON public.manuals;
CREATE POLICY zz_block_family_login ON public.manuals AS RESTRICTIVE FOR ALL TO authenticated
  USING (NOT (SELECT public.auth_is_family()) OR manual_type IN ('financial_literacy','excerpt'))
  WITH CHECK (NOT (SELECT public.auth_is_family()));
ALTER POLICY anon_read_manuals ON public.manuals
  USING ((manual_type = ANY (ARRAY['handbook'::text, 'processes'::text, 'excerpt'::text])) OR is_agency_admin()
         OR (manual_type = 'financial_literacy' AND (SELECT public.auth_is_family())));

-- Weekly chores: set day ---------------------------------------------
ALTER TABLE public.family_chores ADD COLUMN IF NOT EXISTS due_dow smallint CHECK (due_dow BETWEEN 0 AND 6);
COMMENT ON COLUMN public.family_chores.due_dow IS 'Weekly chores only. 0=Sun..6=Sat. NULL = any day that week, due by Saturday.';

ALTER TABLE public.family_ledger DROP CONSTRAINT IF EXISTS family_ledger_kind_check;
ALTER TABLE public.family_ledger ADD CONSTRAINT family_ledger_kind_check
  CHECK (kind IN ('payout','tithe_given','invested','bonus','adjustment','opening_balance'));

-- The date a chore is due for the week or day holding p_date. Only place this rule lives.
CREATE OR REPLACE FUNCTION public.family_occurrence_date(p_chore_id uuid, p_date date)
RETURNS date LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN c.frequency = 'weekly'
              THEN public.family_week_start(p_date) + COALESCE(c.due_dow, 6)
              ELSE p_date END
  FROM public.family_chores c WHERE c.id = p_chore_id;
$$;

CREATE OR REPLACE FUNCTION public.family_set_status(p_chore_id uuid, p_occurrence_date date, p_status text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE v_kid uuid; v_agency uuid; v_occ date; v_row public.family_chore_log;
BEGIN
  IF p_status = 'excused' AND NOT public.family_is_parent() THEN
    RAISE EXCEPTION 'Only a parent can excuse a chore.';
  END IF;
  SELECT kid_id, agency_id INTO v_kid, v_agency FROM public.family_chores WHERE id = p_chore_id;
  IF v_kid IS NULL THEN RAISE EXCEPTION 'chore not found'; END IF;
  v_occ := public.family_occurrence_date(p_chore_id, p_occurrence_date);
  IF p_status IS NULL THEN
    DELETE FROM public.family_chore_log WHERE chore_id = p_chore_id AND occurrence_date = v_occ;
    RETURN jsonb_build_object('cleared', true);
  END IF;
  INSERT INTO public.family_chore_log (agency_id, chore_id, kid_id, occurrence_date, status, amount, note, updated_by)
  VALUES (v_agency, p_chore_id, v_kid, v_occ, p_status, public.family_log_amount(p_chore_id, p_status), p_note, auth.uid())
  ON CONFLICT (chore_id, occurrence_date) DO UPDATE
    SET status = EXCLUDED.status, amount = EXCLUDED.amount,
        note = COALESCE(EXCLUDED.note, public.family_chore_log.note),
        updated_by = EXCLUDED.updated_by, updated_at = now()
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $$;

-- Marks every past, unlogged chore as missed (with its fine). A chore is missed once
-- its due date has passed. Only dates on or after the kid's tracking start and inside
-- the chore's active window count.
CREATE OR REPLACE FUNCTION public.family_sweep_missed()
RETURNS int LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE v_today date := (now() AT TIME ZONE 'America/Chicago')::date; n int;
BEGIN
  WITH base AS (
    SELECT c.id, c.kid_id, c.agency_id, c.frequency, c.active_to,
           GREATEST(k.tracking_start, c.active_from) AS start_d
    FROM public.family_chores c
    JOIN public.family_kids k ON k.id = c.kid_id AND k.is_active
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

-- Everything the screen shows for one kid on one day: that day's daily chores, weekly
-- chores due that day, and weekly chores with no set day. can_act says whether the day
-- can take a check-off yet.
CREATE OR REPLACE FUNCTION public.family_board(p_kid_id uuid, p_date date)
RETURNS TABLE (chore_id uuid, title text, frequency text, part_of_day text, group_label text,
               due_dow smallint, pay numeric, checklist_id uuid, sort_order int,
               occurrence_date date, status text, amount numeric, can_act boolean)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
  WITH k AS (SELECT tracking_start FROM public.family_kids WHERE id = p_kid_id),
  t AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS today),
  ch AS (
    SELECT c.*, public.family_occurrence_date(c.id, p_date) AS occ
    FROM public.family_chores c
    WHERE c.kid_id = p_kid_id
      AND (c.frequency = 'daily' OR c.due_dow IS NULL OR c.due_dow = extract(dow FROM p_date)::int)
  )
  SELECT ch.id, ch.title, ch.frequency, ch.part_of_day, ch.group_label, ch.due_dow, ch.pay,
         ch.checklist_id, ch.sort_order, ch.occ, l.status, l.amount,
         (CASE WHEN ch.frequency = 'weekly' AND ch.due_dow IS NULL
               THEN public.family_week_start(p_date) ELSE ch.occ END) <= t.today
           AND ch.occ >= k.tracking_start
  FROM ch CROSS JOIN k CROSS JOIN t
  LEFT JOIN public.family_chore_log l ON l.chore_id = ch.id AND l.occurrence_date = ch.occ
  WHERE ch.active_from <= ch.occ AND (ch.active_to IS NULL OR ch.active_to >= ch.occ)
  ORDER BY ch.sort_order;
$$;
GRANT EXECUTE ON FUNCTION public.family_occurrence_date(uuid, date), public.family_board(uuid, date) TO authenticated;

-- Set days from Marie's chart (the one un-grayed cell on each weekly row).
UPDATE public.family_chores c SET due_dow = v.dow
FROM (VALUES
  ('Becca','Pick up Poop',NULL,1), ('Becca','Empty Your Bathroom Trash',NULL,5), ('Becca','Vacuum Your Bedroom',NULL,5),
  ('Becca','Clean Your Bathroom (Change Mat)',NULL,5), ('Becca','Wash Dog Bowls',NULL,5), ('Becca','Wash/Dry Your Laundry',NULL,4),
  ('Becca','Put Your Laundry Away',NULL,5), ('Becca','Sweep/Vacuum All Floors','OFFICE',4), ('Becca','Clean Bathroom','OFFICE',4),
  ('Bella','Pick up Poop',NULL,1), ('Bella','Vacuum Downstairs',NULL,5), ('Bella','Vacuum Stairs',NULL,5),
  ('Bella','Vacuum Loft & Spare Room',NULL,5), ('Bella','Mop Downstairs',NULL,5), ('Bella','Vacuum Your Bedroom',NULL,5),
  ('Bella','Wash/Dry Your Laundry',NULL,4), ('Bella','Put Your Laundry Away',NULL,5), ('Bella','Empty All Trash Bins','OFFICE',4),
  ('Bella','Wipe Counters & Microwave','OFFICE',4), ('Bella','Mop all Floors','OFFICE',4)
) v(kid, title, grp, dow)
JOIN public.family_kids k ON k.name = v.kid
WHERE c.kid_id = k.id AND c.frequency = 'weekly' AND c.title = v.title AND c.group_label IS NOT DISTINCT FROM v.grp;

-- Sep 21 went live at 7:30 pm with no way to check anything off; the sweep then fined every chore.
DELETE FROM public.family_chore_log WHERE status = 'missed' AND occurrence_date = DATE '2026-09-21' AND updated_by IS NULL;
UPDATE public.family_kids SET tracking_start = DATE '2026-09-23';

-- Starting balances Peter gave 2026-09-22 (Duck starts at 0).
INSERT INTO public.family_ledger (agency_id, kid_id, entry_date, bucket, kind, amount, note)
SELECT k.agency_id, k.id, DATE '2026-09-22', 'spend', 'opening_balance', v.amt, 'Starting balance'
FROM (VALUES ('Becca', 38.29), ('Bella', -9.73), ('Goose', 213.06)) v(kid, amt)
JOIN public.family_kids k ON k.name = v.kid
WHERE NOT EXISTS (SELECT 1 FROM public.family_ledger l WHERE l.kid_id = k.id AND l.kind = 'opening_balance');

-- Move the financial literacy course out of Admin into its own manual. Rows are updated in
-- place: same ids, same content. The course root becomes the top of the new manual.
WITH RECURSIVE t AS (
  SELECT id, confluence_page_id FROM public.manuals
  WHERE is_active AND manual_type = 'admin' AND confluence_page_id = '2078179331'
  UNION ALL
  SELECT m.id, m.confluence_page_id FROM public.manuals m JOIN t ON m.parent_page_id = t.confluence_page_id
  WHERE m.manual_type = 'admin'
)
UPDATE public.manuals SET manual_type = 'financial_literacy', updated_at = now() WHERE id IN (SELECT id FROM t);
UPDATE public.manuals SET parent_page_id = NULL, updated_at = now()
WHERE manual_type = 'financial_literacy' AND confluence_page_id = '2078179331';
