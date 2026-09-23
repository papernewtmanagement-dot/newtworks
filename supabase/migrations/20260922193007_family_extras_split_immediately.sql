-- Peter 2026-09-22: extra chores (and bonuses) land right away with their tithe and investment split.
-- Only the week's standard chore pay waits for the close-out.
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
    SELECT ((fw.id IS NOT NULL) OR e.kind <> 'chore_pay') AS posted, e.*
    FROM weeks
    LEFT JOIN public.family_weeks fw ON fw.kid_id = p_kid_id AND fw.week_start = weeks.ws
    CROSS JOIN LATERAL public.family_week_events(p_kid_id, weeks.ws) e
  ),
  opening AS (SELECT COALESCE(sum(amount), 0) AS amt FROM public.family_ledger WHERE kid_id = p_kid_id AND kind = 'opening_balance')
  SELECT (SELECT amt FROM opening)
           + COALESCE(sum(ev.amount) FILTER (WHERE ev.bucket = 'spend' AND ev.posted), 0)
           - COALESCE(sum(ev.tithe + ev.invest) FILTER (WHERE ev.posted), 0),
         COALESCE(sum(ev.amount) FILTER (WHERE ev.bucket = 'tithe'), 0) + COALESCE(sum(ev.tithe) FILTER (WHERE ev.posted), 0),
         COALESCE(sum(ev.amount) FILTER (WHERE ev.bucket = 'invest'), 0) + COALESCE(sum(ev.invest) FILTER (WHERE ev.posted), 0),
         COALESCE(sum(ev.amount) FILTER (WHERE NOT ev.posted), 0)
  FROM ev;
$function$;
