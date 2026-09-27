-- Money tab balances (Peter 2026-09-26): "Settles at close-out" is what will land in spending
-- money (after tithe and investments come off), and the history carries a per-week running
-- total of what is still waiting for the close-out.
DROP FUNCTION IF EXISTS public.family_money_history(uuid, date);
CREATE FUNCTION public.family_money_history(p_kid_id uuid, p_through_week date)
 RETURNS TABLE(week_start date, closed boolean, posted boolean, seq integer, event_date date, kind text, label text, bucket text, amount numeric, is_income boolean, tithe numeric, invest numeric, ref_id uuid, math_done boolean, spend_after numeric, waiting_after numeric)
 LANGUAGE sql
 STABLE
AS $function$
  -- The one money history: the starting balance plus every week's events, each marked posted or
  -- still waiting for the close-out. spend_after = spending money after this line (posted lines
  -- only). waiting_after = what this week's waiting lines will add to spending money so far.
  WITH k AS (SELECT tracking_start FROM public.family_kids WHERE id = p_kid_id),
  weeks AS (
    SELECT w::date AS ws FROM k,
    generate_series(public.family_week_start(k.tracking_start), p_through_week, interval '7 days') w
  ),
  ev AS (
    SELECT (SELECT min(ws) FROM weeks) AS ws, true AS closed, true AS posted, 0 AS seq, min(g.entry_date) AS event_date,
           'opening_balance'::text AS kind, 'Starting balance'::text AS label, 'spend'::text AS bucket, sum(g.amount) AS amount,
           false AS is_income, 0::numeric AS tithe, 0::numeric AS invest, NULL::uuid AS ref_id, false AS math_done
    FROM public.family_ledger g WHERE g.kid_id = p_kid_id AND g.kind = 'opening_balance'
    HAVING count(*) > 0
    UNION ALL
    SELECT weeks.ws, fw.id IS NOT NULL, ((fw.id IS NOT NULL) OR e.kind NOT IN ('chore_pay','fines','fine','expense')),
           e.seq, e.event_date, e.kind, e.label, e.bucket, e.amount, e.is_income, e.tithe, e.invest, e.ref_id, e.math_done
    FROM weeks
    LEFT JOIN public.family_weeks fw ON fw.kid_id = p_kid_id AND fw.week_start = weeks.ws
    CROSS JOIN LATERAL public.family_week_events(p_kid_id, weeks.ws) e
  ),
  net AS (SELECT ev.*, (CASE WHEN ev.bucket = 'spend' THEN ev.amount ELSE 0 END) - ev.tithe - ev.invest AS to_spend FROM ev)
  SELECT n.ws, n.closed, n.posted, n.seq, n.event_date, n.kind, n.label, n.bucket, n.amount, n.is_income, n.tithe, n.invest, n.ref_id, n.math_done,
         sum(CASE WHEN n.posted THEN n.to_spend ELSE 0 END) OVER (ORDER BY n.ws, n.seq ROWS UNBOUNDED PRECEDING),
         sum(CASE WHEN n.posted THEN 0 ELSE n.to_spend END) OVER (PARTITION BY n.ws ORDER BY n.seq ROWS UNBOUNDED PRECEDING)
  FROM net n
  ORDER BY n.ws, n.seq;
$function$;
REVOKE ALL ON FUNCTION public.family_money_history(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_money_history(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.family_kid_money(p_kid_id uuid, p_through_week date)
 RETURNS TABLE(spend numeric, tithe numeric, invest numeric, pending numeric)
 LANGUAGE sql
 STABLE
AS $function$
  -- Sums the one money history (family_money_history). pending = what the close-out will add to
  -- spending money, after tithe and investments come off.
  SELECT COALESCE(sum(h.amount) FILTER (WHERE h.bucket = 'spend' AND h.posted), 0)
           - COALESCE(sum(h.tithe + h.invest) FILTER (WHERE h.posted), 0),
         COALESCE(sum(h.amount) FILTER (WHERE h.bucket = 'tithe' AND h.posted), 0) + COALESCE(sum(h.tithe) FILTER (WHERE h.posted), 0),
         COALESCE(sum(h.amount) FILTER (WHERE h.bucket = 'invest' AND h.posted), 0) + COALESCE(sum(h.invest) FILTER (WHERE h.posted), 0),
         COALESCE(sum(CASE WHEN h.bucket = 'spend' THEN h.amount ELSE 0 END - h.tithe - h.invest) FILTER (WHERE NOT h.posted), 0)
  FROM public.family_money_history(p_kid_id, p_through_week) h;
$function$;
