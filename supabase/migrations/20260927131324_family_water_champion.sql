
-- Tag the existing "drink water" chores (already on every kid's board -- Drink Water /
-- Water Bottle 1/2) as the water-consistency category, distinct from other chores that
-- happen to have "water" in the title (e.g. Bella's "Water Dogs" pet chore).
ALTER TABLE public.family_chores ADD COLUMN IF NOT EXISTS is_water boolean NOT NULL DEFAULT false;

UPDATE public.family_chores SET is_water = true
 WHERE id IN (
  'beaf34d2-979a-4c4c-9b40-d825773c1af6', -- Elliott, Water Bottle 2 (evening)
  '3dbfcf40-7fc9-4c82-a3cf-92cf63ccc3c1', -- Elliott, Water Bottle 1 (morning)
  'b359ed9f-602e-489e-8099-cdaea6e0464f', -- Olive, Water Bottle 2 (evening)
  '92c5dc50-9512-4ab1-be28-b27e70fc6f01', -- Olive, Water Bottle 1 (morning)
  'bf7ddf24-73e1-403d-866b-aea051ab598f', -- Becca, Drink Water (evening)
  '20aa03b7-4ca3-472b-b6d9-8c057098c028', -- Becca, Drink Water (morning)
  '4b47814e-e2ca-4ba8-b57f-58e07e8efdf2', -- Bella, Drink Water (afternoon)
  '080daa17-80b3-4652-89df-db8e034809d5'  -- Bella, Drink Water (morning)
 );

-- family_chore_recap generalized with an optional water-only filter (Peter 2026-09-27: a
-- weekly title for who most consistently drinks water, same shape as the chore-completion
-- title). The old 1-arg version is dropped, not left as a parallel implementation -- every
-- existing caller passes through unaffected since the default (false) counts every chore,
-- same as before.
DROP FUNCTION IF EXISTS public.family_chore_recap(date);
CREATE FUNCTION public.family_chore_recap(p_week_start date, p_water_only boolean DEFAULT false)
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
     AND (NOT p_water_only OR c.is_water)
   GROUP BY l.kid_id;
$$;
GRANT EXECUTE ON FUNCTION public.family_chore_recap(date, boolean) TO authenticated;

-- family_week_resolved generalized with a water filter alongside the existing burpees one,
-- so the water title can also confirm the moment the week's last water chore resolves.
DROP FUNCTION IF EXISTS public.family_week_resolved(date, boolean);
CREATE FUNCTION public.family_week_resolved(p_week_start date, p_burpees_only boolean DEFAULT false, p_water_only boolean DEFAULT false)
RETURNS boolean
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  last_day AS (SELECT ws + 6 AS d FROM w),
  due AS (
    SELECT c.id AS chore_id, c.kid_id
      FROM public.family_chores c
      JOIN public.family_kids k ON k.id = c.kid_id AND k.is_active
      CROSS JOIN last_day
     WHERE c.frequency = 'daily'
       AND (NOT p_burpees_only OR c.is_burpees)
       AND (NOT p_water_only OR c.is_water)
       AND last_day.d >= GREATEST(k.tracking_start, c.active_from)
       AND (c.active_to IS NULL OR last_day.d <= c.active_to)
    UNION ALL
    SELECT c.id, c.kid_id
      FROM public.family_chores c
      JOIN public.family_kids k ON k.id = c.kid_id AND k.is_active
      CROSS JOIN last_day
     WHERE c.frequency = 'weekly'
       AND (NOT p_burpees_only OR c.is_burpees)
       AND (NOT p_water_only OR c.is_water)
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
GRANT EXECUTE ON FUNCTION public.family_week_resolved(date, boolean, boolean) TO authenticated;

-- Weekly Water title: same shape as Burpee King / Chore Champion (Peter 2026-09-27).
CREATE OR REPLACE FUNCTION public.family_water_winners(p_week_start date)
RETURNS TABLE(kid_id uuid, pct numeric, title text)
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  r AS (SELECT * FROM public.family_chore_recap(p_week_start, true) WHERE total > 0),
  top AS (SELECT max(pct) AS best FROM r),
  ranked AS (
    SELECT r.kid_id, r.pct
      FROM r JOIN top ON r.pct = top.best AND top.best > 0
     ORDER BY r.fines_count ASC, r.done DESC
     LIMIT 1
  ),
  cnt AS (SELECT count(*)::int AS n FROM public.family_burpee_titles),
  idx AS (SELECT CASE WHEN cnt.n > 0 THEN ((((w.ws - DATE '2026-09-19') / 7 + 2) % cnt.n) + cnt.n) % cnt.n END AS i FROM w CROSS JOIN cnt),
  word AS (
    SELECT rr.boy, rr.girl
      FROM (SELECT boy, girl, (row_number() OVER (ORDER BY sort_order, id) - 1)::int AS rn FROM public.family_burpee_titles) rr
      JOIN idx ON rr.rn = idx.i
  )
  SELECT ranked.kid_id, ranked.pct,
         'Water ' || COALESCE(CASE WHEN k.gender = 'girl' THEN wd.girl
                                    WHEN k.gender = 'boy' THEN wd.boy
                                    WHEN wd.boy = wd.girl THEN wd.boy END, 'Champion')
    FROM ranked
    JOIN public.family_kids k ON k.id = ranked.kid_id
    CROSS JOIN w
    LEFT JOIN word wd ON true
   WHERE (now() AT TIME ZONE 'America/Chicago')::date > w.ws + 6
      OR ((now() AT TIME ZONE 'America/Chicago')::date = w.ws + 6 AND public.family_week_resolved(w.ws, false, true));
$$;
GRANT EXECUTE ON FUNCTION public.family_water_winners(date) TO authenticated;

-- Add the water category to the reveal leaderboard.
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
    LEFT JOIN public.family_chore_recap(p_week_start, false) r ON r.kid_id = k.id
    LEFT JOIN public.family_chore_winners(p_week_start) cw ON cw.kid_id = k.id
   WHERE k.is_active AND COALESCE(r.total, 0) > 0
  UNION ALL
  SELECT 'water', k.id, k.name, COALESCE(wr.pct, 0), 'pct', ww.kid_id IS NOT NULL, ww.title
    FROM public.family_kids k
    LEFT JOIN public.family_chore_recap(p_week_start, true) wr ON wr.kid_id = k.id
    LEFT JOIN public.family_water_winners(p_week_start) ww ON ww.kid_id = k.id
   WHERE k.is_active AND EXISTS (SELECT 1 FROM public.family_chores c WHERE c.kid_id = k.id AND c.is_water)
   ORDER BY 1, 4 DESC;
$$;

-- Carry the water title into the following week's day-done celebration too, same as the
-- burpee and chore titles.
DROP FUNCTION IF EXISTS public.family_burpee_week(date);
CREATE FUNCTION public.family_burpee_week(p_week_start date)
RETURNS TABLE(kid_id uuid, points integer, sessions integer, best_seconds integer, champion_title text, chore_title text, water_title text)
LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  s AS (SELECT * FROM public.family_burpee_sessions()),
  wk AS (SELECT s.kid_id, sum(s.points)::int AS points, count(*)::int AS sessions
           FROM s CROSS JOIN w WHERE s.on_date BETWEEN w.ws AND w.ws + 6 GROUP BY s.kid_id),
  best AS (SELECT s.kid_id, min(s.seconds)::int AS best_seconds
             FROM s CROSS JOIN w WHERE s.counted AND s.on_date <= w.ws + 6 GROUP BY s.kid_id),
  champ AS (SELECT c.kid_id, c.title FROM w CROSS JOIN LATERAL public.family_burpee_winners(w.ws - 7) c),
  chore_champ AS (SELECT c.kid_id, c.title FROM w CROSS JOIN LATERAL public.family_chore_winners(w.ws - 7) c),
  water_champ AS (SELECT c.kid_id, c.title FROM w CROSS JOIN LATERAL public.family_water_winners(w.ws - 7) c)
  SELECT k.id, COALESCE(wk.points, 0), COALESCE(wk.sessions, 0), best.best_seconds, champ.title, chore_champ.title, water_champ.title
    FROM public.family_kids k
    LEFT JOIN wk ON wk.kid_id = k.id
    LEFT JOIN best ON best.kid_id = k.id
    LEFT JOIN champ ON champ.kid_id = k.id
    LEFT JOIN chore_champ ON chore_champ.kid_id = k.id
    LEFT JOIN water_champ ON water_champ.kid_id = k.id
   WHERE k.is_active
   ORDER BY k.sort_order;
$$;
GRANT EXECUTE ON FUNCTION public.family_burpee_week(date) TO authenticated;

