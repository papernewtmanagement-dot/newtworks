-- Peter 2026-09-22: fines and expenses also tally for the week and settle at the close-out.
-- Parents keep a list of expenses; the hub or a parent adds one to a kid's week.

-- 1. Expense list.
CREATE TABLE IF NOT EXISTS public.family_expense_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365' REFERENCES public.agency(id),
  name text NOT NULL,
  amount numeric(8,2) NOT NULL CHECK (amount > 0),
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.family_expense_types ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS family_expense_types_family_read ON public.family_expense_types;
CREATE POLICY family_expense_types_family_read ON public.family_expense_types FOR SELECT
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT auth_is_family()));
DROP POLICY IF EXISTS family_expense_types_parents_all ON public.family_expense_types;
CREATE POLICY family_expense_types_parents_all ON public.family_expense_types FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.family_expense_types TO authenticated;

INSERT INTO public.family_expense_types (name, amount, sort_order)
SELECT 'Bubble bath', 0.50, 1 WHERE NOT EXISTS (SELECT 1 FROM public.family_expense_types WHERE name = 'Bubble bath');

ALTER TABLE public.family_ledger ADD COLUMN IF NOT EXISTS expense_type_id uuid REFERENCES public.family_expense_types(id) ON DELETE SET NULL;
ALTER TABLE public.family_ledger DROP CONSTRAINT IF EXISTS family_ledger_kind_check;
ALTER TABLE public.family_ledger ADD CONSTRAINT family_ledger_kind_check
  CHECK (kind = ANY (ARRAY['payout','tithe_given','invested','bonus','adjustment','opening_balance','fine','expense']));
ALTER TABLE public.family_ledger DROP CONSTRAINT IF EXISTS family_ledger_expense_negative;
ALTER TABLE public.family_ledger ADD CONSTRAINT family_ledger_expense_negative CHECK (kind <> 'expense' OR (amount < 0 AND bucket = 'spend'));

-- The hub may add expenses only; everything else in the ledger is a parent's job.
DROP POLICY IF EXISTS family_ledger_family_insert ON public.family_ledger;
CREATE POLICY family_ledger_family_insert ON public.family_ledger FOR INSERT
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT auth_is_family()) AND kind = 'expense');

-- 2. Register: expenses labeled; the week's pay comes first in the close-out, then fines and expenses by date.
CREATE OR REPLACE FUNCTION public.family_week_events(p_kid_id uuid, p_week_start date)
 RETURNS TABLE(seq integer, event_date date, kind text, label text, bucket text, amount numeric, is_income boolean, tithe numeric, invest numeric, ref_id uuid, math_done boolean)
 LANGUAGE sql
 STABLE
AS $function$
  WITH k AS (SELECT tithe_pct, invest_pct FROM public.family_kids WHERE id = p_kid_id),
  logs AS (
    SELECT l.id, l.occurrence_date AS d, l.amount, c.frequency, c.title
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

-- 3. Posting: chore pay, missed-chore fines, given fines and expenses wait for the close-out.
--    Bonuses, cash out, tithe given, invested and adjustments post right away.
CREATE OR REPLACE FUNCTION public.family_kid_money(p_kid_id uuid, p_through_week date)
 RETURNS TABLE(spend numeric, tithe numeric, invest numeric, pending numeric)
 LANGUAGE sql
 STABLE
AS $function$
  WITH k AS (SELECT tracking_start FROM public.family_kids WHERE id = p_kid_id),
  weeks AS (
    SELECT w::date AS ws FROM k,
    generate_series(public.family_week_start(k.tracking_start), p_through_week, interval '7 days') w
  ),
  ev AS (
    SELECT ((fw.id IS NOT NULL) OR e.kind NOT IN ('chore_pay','fines','fine','expense')) AS posted, e.*
    FROM weeks
    LEFT JOIN public.family_weeks fw ON fw.kid_id = p_kid_id AND fw.week_start = weeks.ws
    CROSS JOIN LATERAL public.family_week_events(p_kid_id, weeks.ws) e
  ),
  opening AS (SELECT COALESCE(sum(amount), 0) AS amt FROM public.family_ledger WHERE kid_id = p_kid_id AND kind = 'opening_balance')
  SELECT (SELECT amt FROM opening)
           + COALESCE(sum(ev.amount) FILTER (WHERE ev.bucket = 'spend' AND ev.posted), 0)
           - COALESCE(sum(ev.tithe + ev.invest) FILTER (WHERE ev.posted), 0),
         COALESCE(sum(ev.amount) FILTER (WHERE ev.bucket = 'tithe' AND ev.posted), 0) + COALESCE(sum(ev.tithe) FILTER (WHERE ev.posted), 0),
         COALESCE(sum(ev.amount) FILTER (WHERE ev.bucket = 'invest' AND ev.posted), 0) + COALESCE(sum(ev.invest) FILTER (WHERE ev.posted), 0),
         COALESCE(sum(ev.amount) FILTER (WHERE NOT ev.posted), 0)
  FROM ev;
$function$;

-- 4. Balances: week fines include given fines; new week_spent for expenses.
DROP FUNCTION IF EXISTS public.family_balances(date);
CREATE FUNCTION public.family_balances(p_week_start date DEFAULT NULL::date)
 RETURNS TABLE(kid_id uuid, name text, spend numeric, tithe numeric, invest numeric, pending_pay numeric, week_earned numeric, week_fines numeric, week_spent numeric, week_possible numeric, next_close date)
 LANGUAGE sql
 STABLE
AS $function$
  WITH t AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS today),
  wk AS (SELECT COALESCE(p_week_start, public.family_week_start(t.today)) AS ws FROM t),
  tw AS (
    SELECT l.kid_id, sum(l.amount) FILTER (WHERE l.amount > 0) AS earned, sum(l.amount) FILTER (WHERE l.amount < 0) AS fines
    FROM public.family_chore_log l, wk WHERE l.occurrence_date BETWEEN wk.ws AND wk.ws + 6 GROUP BY 1
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
GRANT EXECUTE ON FUNCTION public.family_balances(date) TO authenticated, service_role;
