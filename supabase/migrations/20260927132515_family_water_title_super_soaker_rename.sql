
-- Peter 2026-09-27: rename the water-consistency title to a Super Soaker theme.
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
         'Super Soaker ' || COALESCE(CASE WHEN k.gender = 'girl' THEN wd.girl
                                    WHEN k.gender = 'boy' THEN wd.boy
                                    WHEN wd.boy = wd.girl THEN wd.boy END, 'Champion')
    FROM ranked
    JOIN public.family_kids k ON k.id = ranked.kid_id
    CROSS JOIN w
    LEFT JOIN word wd ON true
   WHERE (now() AT TIME ZONE 'America/Chicago')::date > w.ws + 6
      OR ((now() AT TIME ZONE 'America/Chicago')::date = w.ws + 6 AND public.family_week_resolved(w.ws, false, true));
$$;

