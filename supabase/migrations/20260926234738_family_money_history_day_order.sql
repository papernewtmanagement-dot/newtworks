-- Money history order inside a day (Peter 2026-09-26): missed chores, then the week's chore pay,
-- then its tithe and investment set-asides, then that day's fines and expenses.
CREATE OR REPLACE FUNCTION public.family_money_history(p_kid_id uuid, p_through_week date)
 RETURNS TABLE(week_start date, closed boolean, posted boolean, seq integer, sub integer, event_date date, kind text, label text, bucket text, amount numeric, to_spend numeric, ref_id uuid, spend_after numeric, waiting_after numeric)
 LANGUAGE sql
 STABLE
AS $function$
  -- The one money history. One line per money event, oldest to newest; income is followed by its
  -- tithe and investment set-asides as their own lines. Inside a day: starting balance, missed
  -- chores, chore pay and its set-asides, then everything else (Peter 2026-09-26).
  -- amount = what the line moves into its bucket (spend, tithe or invest); to_spend = what it does
  -- to spending money. Posted lines count now; the rest wait for the week's close-out.
  -- spend_after = spending money after the line. waiting_after = what this week's waiting lines
  -- will add to spending money so far.
  WITH k AS (SELECT tracking_start FROM public.family_kids WHERE id = p_kid_id),
  weeks AS (
    SELECT w::date AS ws FROM k,
    generate_series(public.family_week_start(k.tracking_start), p_through_week, interval '7 days') w
  ),
  ev AS (
    SELECT (SELECT min(ws) FROM weeks) AS ws, true AS closed, true AS posted, 0 AS seq, min(g.entry_date) AS event_date,
           'opening_balance'::text AS kind, 'Starting balance'::text AS label, 'spend'::text AS bucket, sum(g.amount) AS amount,
           0::numeric AS tithe, 0::numeric AS invest, NULL::uuid AS ref_id
    FROM public.family_ledger g WHERE g.kid_id = p_kid_id AND g.kind = 'opening_balance'
    HAVING count(*) > 0
    UNION ALL
    SELECT weeks.ws, fw.id IS NOT NULL, ((fw.id IS NOT NULL) OR e.kind NOT IN ('chore_pay','fines','fine','expense')),
           e.seq, e.event_date, e.kind, e.label, e.bucket, e.amount,
           CASE WHEN e.is_income THEN e.tithe ELSE 0 END, CASE WHEN e.is_income THEN e.invest ELSE 0 END, e.ref_id
    FROM weeks
    LEFT JOIN public.family_weeks fw ON fw.kid_id = p_kid_id AND fw.week_start = weeks.ws
    CROSS JOIN LATERAL public.family_week_events(p_kid_id, weeks.ws) e
  ),
  lines AS (
    SELECT ev.ws, ev.closed, ev.posted, ev.seq, 0 AS sub, ev.event_date, ev.kind, ev.label, ev.bucket, ev.amount,
           CASE WHEN ev.bucket = 'spend' THEN ev.amount ELSE 0 END AS to_spend, ev.ref_id,
           CASE ev.kind WHEN 'opening_balance' THEN 0 WHEN 'fines' THEN 1 WHEN 'chore_pay' THEN 2 ELSE 3 END AS rank
    FROM ev
    UNION ALL
    SELECT ev.ws, ev.closed, ev.posted, ev.seq, 1, ev.event_date, 'tithe_set_aside', 'Set aside for tithe', 'tithe', ev.tithe, -ev.tithe, ev.ref_id,
           CASE ev.kind WHEN 'chore_pay' THEN 2 ELSE 3 END
    FROM ev WHERE ev.tithe <> 0
    UNION ALL
    SELECT ev.ws, ev.closed, ev.posted, ev.seq, 2, ev.event_date, 'invest_set_aside', 'Set aside for investments', 'invest', ev.invest, -ev.invest, ev.ref_id,
           CASE ev.kind WHEN 'chore_pay' THEN 2 ELSE 3 END
    FROM ev WHERE ev.invest <> 0
  )
  SELECT l.ws, l.closed, l.posted, l.seq, l.sub, l.event_date, l.kind, l.label, l.bucket, l.amount, l.to_spend, l.ref_id,
         sum(CASE WHEN l.posted THEN l.to_spend ELSE 0 END) OVER (ORDER BY l.ws, l.event_date, l.rank, l.seq, l.sub ROWS UNBOUNDED PRECEDING),
         sum(CASE WHEN l.posted THEN 0 ELSE l.to_spend END) OVER (PARTITION BY l.ws ORDER BY l.event_date, l.rank, l.seq, l.sub ROWS UNBOUNDED PRECEDING)
  FROM lines l
  ORDER BY l.ws, l.event_date, l.rank, l.seq, l.sub;
$function$;
