-- Peter 2026-09-22: chore pay and chore fines for a week that is not closed are worked out from the
-- current prices every time they are shown. Closing the week locks each entry's amount.

-- The one rule for what a chore entry is worth.
CREATE OR REPLACE FUNCTION public.family_entry_amount(p_chore_id uuid, p_kid_id uuid, p_status text, p_occ date, p_stored numeric)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.family_weeks w WHERE w.kid_id = p_kid_id AND w.week_start = public.family_week_start(p_occ))
      THEN p_stored
    ELSE public.family_log_amount(p_chore_id, p_status, p_occ)
  END;
$function$;
GRANT EXECUTE ON FUNCTION public.family_entry_amount(uuid, uuid, text, date, numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.family_week_events(p_kid_id uuid, p_week_start date)
 RETURNS TABLE(seq integer, event_date date, kind text, label text, bucket text, amount numeric, is_income boolean, tithe numeric, invest numeric, ref_id uuid, math_done boolean)
 LANGUAGE sql
 STABLE
AS $function$
  WITH k AS (SELECT tithe_pct, invest_pct FROM public.family_kids WHERE id = p_kid_id),
  logs AS (
    SELECT l.id, l.occurrence_date AS d,
           public.family_entry_amount(l.chore_id, l.kid_id, l.status, l.occurrence_date, l.amount) AS amount,
           c.frequency, c.title
    FROM public.family_chore_log l JOIN public.family_chores c ON c.id = l.chore_id
    WHERE l.kid_id = p_kid_id AND l.occurrence_date BETWEEN p_week_start AND p_week_start + 6
  ),
  ev AS (
    SELECT p_week_start + 6 AS event_date, 0 AS ord, 'chore_pay' AS kind, 'Chores this week' AS label, 'spend' AS bucket,
           sum(amount) AS amount, true AS is_income, NULL::uuid AS ref_id, false AS math_done
    FROM logs WHERE amount > 0 HAVING sum(amount) > 0
    UNION ALL
    SELECT d, 1, 'fines',
           trim(to_char(d, 'Day')) || ': ' || count(*) || CASE WHEN count(*) = 1 THEN ' missed chore' ELSE ' missed chores' END,
           'spend', sum(amount), false, NULL::uuid, false
    FROM logs WHERE amount < 0 GROUP BY d
    UNION ALL
    SELECT entry_date, 2, kind,
           CASE kind WHEN 'payout' THEN 'Cash paid out' WHEN 'bonus' THEN 'Bonus' WHEN 'adjustment' THEN 'Adjustment'
                     WHEN 'tithe_given' THEN 'Tithe given' WHEN 'invested' THEN 'Invested' WHEN 'fine' THEN 'Fine'
                     WHEN 'expense' THEN 'Spent' ELSE kind END
             || COALESCE(' · ' || note, ''),
           bucket, amount, (kind = 'bonus'), id, math_done_at IS NOT NULL
    FROM public.family_ledger
    WHERE kid_id = p_kid_id AND kind <> 'opening_balance' AND entry_date BETWEEN p_week_start AND p_week_start + 6
  )
  SELECT (row_number() OVER (ORDER BY CASE WHEN ev.kind = 'chore_pay' THEN 0 ELSE 1 END, ev.event_date, ev.ord, ev.label))::int,
         ev.event_date, ev.kind, ev.label, ev.bucket, ev.amount, ev.is_income,
         CASE WHEN ev.is_income THEN public.family_set_aside(ev.amount, k.tithe_pct) ELSE 0 END,
         CASE WHEN ev.is_income THEN public.family_set_aside(ev.amount, k.invest_pct) ELSE 0 END,
         ev.ref_id, ev.math_done
  FROM ev CROSS JOIN k
  ORDER BY 1;
$function$;

CREATE OR REPLACE FUNCTION public.family_balances(p_week_start date DEFAULT NULL::date)
 RETURNS TABLE(kid_id uuid, name text, spend numeric, tithe numeric, invest numeric, pending_pay numeric, week_earned numeric, week_fines numeric, week_spent numeric, week_possible numeric, next_close date)
 LANGUAGE sql
 STABLE
AS $function$
  WITH t AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS today),
  wk AS (SELECT COALESCE(p_week_start, public.family_week_start(t.today)) AS ws FROM t),
  la AS (
    SELECT l.kid_id, public.family_entry_amount(l.chore_id, l.kid_id, l.status, l.occurrence_date, l.amount) AS amount
    FROM public.family_chore_log l, wk WHERE l.occurrence_date BETWEEN wk.ws AND wk.ws + 6
  ),
  tw AS (
    SELECT la.kid_id, sum(la.amount) FILTER (WHERE la.amount > 0) AS earned, sum(la.amount) FILTER (WHERE la.amount < 0) AS fines
    FROM la GROUP BY 1
  ),
  lw AS (
    SELECT g.kid_id, sum(g.amount) FILTER (WHERE g.kind = 'fine') AS fines, sum(g.amount) FILTER (WHERE g.kind = 'expense') AS spent
    FROM public.family_ledger g, wk WHERE g.entry_date BETWEEN wk.ws AND wk.ws + 6 GROUP BY 1
  ),
  possible AS (
    SELECT c.kid_id, sum(c.pay * CASE WHEN c.frequency = 'daily' THEN 7 ELSE 1 END) AS amt
    FROM public.family_chores c, wk
    WHERE c.frequency IN ('daily','weekly') AND c.active_from <= wk.ws + 6 AND (c.active_to IS NULL OR c.active_to >= wk.ws)
    GROUP BY 1
  )
  SELECT k.id, k.name, m.spend, m.tithe, m.invest, m.pending,
         COALESCE(tw.earned, 0), COALESCE(tw.fines, 0) + COALESCE(lw.fines, 0), COALESCE(lw.spent, 0), COALESCE(p.amt, 0),
         (SELECT min(w::date) FROM generate_series(public.family_week_start(k.tracking_start), public.family_week_start(t.today) - 7, interval '7 days') w
          WHERE NOT EXISTS (SELECT 1 FROM public.family_weeks f WHERE f.kid_id = k.id AND f.week_start = w::date))
  FROM public.family_kids k
  CROSS JOIN t
  CROSS JOIN LATERAL public.family_kid_money(k.id, public.family_week_start(t.today)) m
  LEFT JOIN tw ON tw.kid_id = k.id
  LEFT JOIN lw ON lw.kid_id = k.id
  LEFT JOIN possible p ON p.kid_id = k.id
  WHERE k.is_active
  ORDER BY k.sort_order;
$function$;

CREATE OR REPLACE FUNCTION public.family_week_board(p_kid_id uuid, p_week_start date)
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
    SELECT a.*, l.status, l.burpee_count, t.parent,
           CASE WHEN l.id IS NOT NULL THEN public.family_entry_amount(l.chore_id, l.kid_id, l.status, l.occurrence_date, l.amount) END AS amount,
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

-- Close-out: lock every entry of the week at today's prices, then record the week.
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
  IF EXISTS (SELECT 1 FROM public.family_weeks f WHERE f.kid_id = p_kid_id AND f.week_start = p_week_start) THEN
    RETURN (SELECT to_jsonb(m) FROM public.family_kid_money(p_kid_id, public.family_week_start(v_today)) m);
  END IF;
  PERFORM public.family_sweep_missed();
  UPDATE public.family_chore_log l
     SET amount = public.family_log_amount(l.chore_id, l.status, l.occurrence_date), updated_at = now()
   WHERE l.kid_id = p_kid_id AND l.occurrence_date BETWEEN p_week_start AND p_week_start + 6;
  INSERT INTO public.family_weeks (agency_id, kid_id, week_start, closed_by, solved_by_parent, register)
  VALUES (v_agency, p_kid_id, p_week_start, auth.uid(), p_solved_by_parent, public.family_week_register(p_kid_id, p_week_start))
  ON CONFLICT (kid_id, week_start) DO NOTHING;
  RETURN (SELECT to_jsonb(m) FROM public.family_kid_money(p_kid_id, public.family_week_start(v_today)) m);
END $function$;
