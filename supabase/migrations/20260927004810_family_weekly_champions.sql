-- Family: weekly champions announcement + a second category (Chore Champion) + fix
-- the "champion shown at the wrong time" bug (Peter 2026-09-27).

ALTER TABLE public.family_settings ADD COLUMN IF NOT EXISTS champs_announced_week date;

-- Chore completion recap for a week: how reliably each kid did their real chores
-- (extras excluded -- those are optional bonus work, not a fairness measure).
CREATE OR REPLACE FUNCTION public.family_chore_recap(p_week_start date)
RETURNS TABLE(kid_id uuid, done integer, total integer, pct numeric, fines_count integer)
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws)
  SELECT l.kid_id,
         count(*) FILTER (WHERE l.status IN ('claimed','verified'))::int,
         count(*) FILTER (WHERE l.status IN ('claimed','verified','missed','false_claim'))::int,
         round(100.0 * count(*) FILTER (WHERE l.status IN ('claimed','verified'))
               / NULLIF(count(*) FILTER (WHERE l.status IN ('claimed','verified','missed','false_claim')), 0), 1),
         count(*) FILTER (WHERE l.status IN ('missed','false_claim'))::int
    FROM public.family_chore_log l
    JOIN public.family_chores c ON c.id = l.chore_id
   CROSS JOIN w
   WHERE c.frequency <> 'extra' AND l.occurrence_date BETWEEN w.ws AND w.ws + 6
   GROUP BY l.kid_id;
$$;

-- Chore Champion for a week: highest completion percentage (min 1 eligible chore),
-- tie broken by fewest fines then by who did the most. Reuses the same rotating
-- title list as burpees, offset by one slot so the two titles usually differ,
-- and only resolves once the week is actually over (Peter 2026-09-26 rule mirrored).
CREATE OR REPLACE FUNCTION public.family_chore_winners(p_week_start date)
RETURNS TABLE(kid_id uuid, pct numeric, title text)
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  r AS (SELECT * FROM public.family_chore_recap(p_week_start) WHERE total > 0),
  top AS (SELECT max(pct) AS best FROM r),
  ranked AS (
    SELECT r.kid_id, r.pct
      FROM r JOIN top ON r.pct = top.best AND top.best > 0
     ORDER BY r.fines_count ASC, r.done DESC
     LIMIT 1
  ),
  cnt AS (SELECT count(*)::int AS n FROM public.family_burpee_titles),
  idx AS (SELECT CASE WHEN cnt.n > 0 THEN ((((w.ws - DATE '2026-09-19') / 7 + 1) % cnt.n) + cnt.n) % cnt.n END AS i FROM w CROSS JOIN cnt),
  word AS (
    SELECT rr.boy, rr.girl
      FROM (SELECT boy, girl, (row_number() OVER (ORDER BY sort_order, id) - 1)::int AS rn FROM public.family_burpee_titles) rr
      JOIN idx ON rr.rn = idx.i
  )
  SELECT ranked.kid_id, ranked.pct,
         'Chore ' || COALESCE(CASE WHEN k.gender = 'girl' THEN wd.girl
                                    WHEN k.gender = 'boy' THEN wd.boy
                                    WHEN wd.boy = wd.girl THEN wd.boy END, 'Champion')
    FROM ranked
    JOIN public.family_kids k ON k.id = ranked.kid_id
    CROSS JOIN w
    LEFT JOIN word wd ON true
   WHERE (now() AT TIME ZONE 'America/Chicago')::date > w.ws + 6;
$$;

-- Full recap for the announcement: every active kid, both categories, so the
-- reveal can show how everyone compared, not just who won.
CREATE OR REPLACE FUNCTION public.family_champs_recap(p_week_start date)
RETURNS TABLE(category text, kid_id uuid, kid_name text, score numeric, unit text, is_champion boolean, title text)
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  bp AS (SELECT s.kid_id, sum(s.points)::int AS points FROM public.family_burpee_sessions() s CROSS JOIN w WHERE s.on_date BETWEEN w.ws AND w.ws + 6 GROUP BY s.kid_id)
  SELECT 'burpee', k.id, k.name, COALESCE(bp.points, 0)::numeric, 'points', bw.kid_id IS NOT NULL, bw.title
    FROM public.family_kids k
    CROSS JOIN w
    LEFT JOIN bp ON bp.kid_id = k.id
    LEFT JOIN public.family_burpee_winners(p_week_start) bw ON bw.kid_id = k.id
   WHERE k.is_active AND EXISTS (SELECT 1 FROM public.family_chores c WHERE c.kid_id = k.id AND c.is_burpees)
  UNION ALL
  SELECT 'chores', k.id, k.name, COALESCE(r.pct, 0), 'pct', cw.kid_id IS NOT NULL, cw.title
    FROM public.family_kids k
    LEFT JOIN public.family_chore_recap(p_week_start) r ON r.kid_id = k.id
    LEFT JOIN public.family_chore_winners(p_week_start) cw ON cw.kid_id = k.id
   WHERE k.is_active AND COALESCE(r.total, 0) > 0
   ORDER BY 1, 4 DESC;
$$;

-- One-time ack so the reveal shows once per household per week, not on every visit.
CREATE OR REPLACE FUNCTION public.family_champs_ack(p_week_start date)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $$
  UPDATE public.family_settings
     SET champs_announced_week = GREATEST(COALESCE(champs_announced_week, p_week_start), p_week_start),
         updated_at = now();
$$;

GRANT EXECUTE ON FUNCTION public.family_chore_recap(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.family_chore_winners(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.family_champs_recap(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.family_champs_ack(date) TO authenticated;

-- family_burpee_week gains chore_title (this week's ambient trophy needs both
-- titles, same as it already carries champion_title for burpees). Return shape
-- changes, so drop + recreate.
DROP FUNCTION IF EXISTS public.family_burpee_week(date);
CREATE FUNCTION public.family_burpee_week(p_week_start date)
RETURNS TABLE(kid_id uuid, points integer, sessions integer, best_seconds integer, champion_title text, chore_title text)
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  s AS (SELECT * FROM public.family_burpee_sessions()),
  wk AS (SELECT s.kid_id, sum(s.points)::int AS points, count(*)::int AS sessions
           FROM s CROSS JOIN w WHERE s.on_date BETWEEN w.ws AND w.ws + 6 GROUP BY s.kid_id),
  best AS (SELECT s.kid_id, min(s.seconds)::int AS best_seconds
             FROM s CROSS JOIN w WHERE s.counted AND s.on_date <= w.ws + 6 GROUP BY s.kid_id),
  champ AS (SELECT c.kid_id, c.title FROM w CROSS JOIN LATERAL public.family_burpee_winners(w.ws - 7) c),
  chore_champ AS (SELECT c.kid_id, c.title FROM w CROSS JOIN LATERAL public.family_chore_winners(w.ws - 7) c)
  SELECT k.id, COALESCE(wk.points, 0), COALESCE(wk.sessions, 0), best.best_seconds, champ.title, chore_champ.title
    FROM public.family_kids k
    LEFT JOIN wk ON wk.kid_id = k.id
    LEFT JOIN best ON best.kid_id = k.id
    LEFT JOIN champ ON champ.kid_id = k.id
    LEFT JOIN chore_champ ON chore_champ.kid_id = k.id
   WHERE k.is_active
   ORDER BY k.sort_order;
$$;
GRANT EXECUTE ON FUNCTION public.family_burpee_week(date) TO authenticated;

