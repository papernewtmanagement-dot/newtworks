
CREATE OR REPLACE FUNCTION public.family_week_resolved(p_week_start date, p_burpees_only boolean DEFAULT false)
RETURNS boolean
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  -- True once every active kid's chores due on the week's last day (the week runs Sat-Fri, so
  -- this is Friday) have a resolved status -- claimed, verified, missed, false_claim, excused or
  -- carried -- rather than waiting for the calendar day to turn over. Lets a title be confirmed
  -- the moment the last relevant chore of the week is actually acted on (Peter 2026-09-27): for
  -- burpees, as soon as everyone's afternoon Burpees chore for Friday is resolved; for the chore
  -- title, once every chore due that Friday is resolved.
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  last_day AS (SELECT ws + 6 AS d FROM w),
  due AS (
    SELECT c.id AS chore_id, c.kid_id
      FROM public.family_chores c
      JOIN public.family_kids k ON k.id = c.kid_id AND k.is_active
      CROSS JOIN last_day
     WHERE c.frequency = 'daily'
       AND (NOT p_burpees_only OR c.is_burpees)
       AND last_day.d >= GREATEST(k.tracking_start, c.active_from)
       AND (c.active_to IS NULL OR last_day.d <= c.active_to)
    UNION ALL
    SELECT c.id, c.kid_id
      FROM public.family_chores c
      JOIN public.family_kids k ON k.id = c.kid_id AND k.is_active
      CROSS JOIN last_day
     WHERE c.frequency = 'weekly'
       AND (NOT p_burpees_only OR c.is_burpees)
       AND public.family_occurrence_date(c.id, last_day.d) = last_day.d
       AND last_day.d >= GREATEST(k.tracking_start, c.active_from)
       AND (c.active_to IS NULL OR last_day.d <= c.active_to)
  )
  SELECT NOT EXISTS (
    SELECT 1
      FROM due d
      CROSS JOIN last_day
      LEFT JOIN public.family_chore_log l
        ON l.chore_id = d.chore_id AND l.kid_id = d.kid_id AND l.occurrence_date = last_day.d
     WHERE l.status IS NULL OR l.status NOT IN ('claimed','verified','missed','false_claim','excused','carried')
  );
$$;

GRANT EXECUTE ON FUNCTION public.family_week_resolved(date, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.family_burpee_winners(p_week_start date)
RETURNS TABLE(kid_id uuid, points integer, title text)
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  pts AS (
    SELECT s.kid_id, sum(s.points)::int AS points
      FROM public.family_burpee_sessions() s CROSS JOIN w
     WHERE s.on_date BETWEEN w.ws AND w.ws + 6
     GROUP BY s.kid_id
  ),
  top AS (SELECT max(points) AS best FROM pts),
  cnt AS (SELECT count(*)::int AS n FROM public.family_burpee_titles),
  idx AS (SELECT CASE WHEN cnt.n > 0 THEN ((((w.ws - DATE '2026-09-19') / 7) % cnt.n) + cnt.n) % cnt.n END AS i FROM w CROSS JOIN cnt),
  word AS (
    SELECT r.boy, r.girl
      FROM (SELECT boy, girl, (row_number() OVER (ORDER BY sort_order, id) - 1)::int AS rn FROM public.family_burpee_titles) r
      JOIN idx ON r.rn = idx.i
  )
  SELECT p.kid_id, p.points,
         'Burpee ' || COALESCE(CASE WHEN k.gender = 'girl' THEN wd.girl
                                    WHEN k.gender = 'boy' THEN wd.boy
                                    WHEN wd.boy = wd.girl THEN wd.boy END, 'Champion')
    FROM pts p
    JOIN top ON p.points = top.best AND top.best > 0
    JOIN public.family_kids k ON k.id = p.kid_id
    CROSS JOIN w
    LEFT JOIN word wd ON true
   WHERE (now() AT TIME ZONE 'America/Chicago')::date > w.ws + 6
      OR ((now() AT TIME ZONE 'America/Chicago')::date = w.ws + 6 AND public.family_week_resolved(w.ws, true));
$$;

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
   WHERE (now() AT TIME ZONE 'America/Chicago')::date > w.ws + 6
      OR ((now() AT TIME ZONE 'America/Chicago')::date = w.ws + 6 AND public.family_week_resolved(w.ws, false));
$$;

