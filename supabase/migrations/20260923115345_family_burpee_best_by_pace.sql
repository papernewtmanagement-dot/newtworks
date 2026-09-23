-- A personal best is the kid's best pace (seconds per burpee) over earlier runs that
-- counted, turned into the time that pace gives for this run's number of burpees
-- (Peter 2026-09-23). Same as the best time whenever the number is the same; a
-- birthday or a carried set no longer puts the old best out of reach. Rounded up to
-- the whole second (after trimming division dust), so "beats your best" stays exact
-- for runs timed in seconds.
-- family_burpee_points is unchanged: it still gets this run's time and that best.
CREATE OR REPLACE FUNCTION public.family_burpee_sessions()
RETURNS TABLE(id uuid, kid_id uuid, on_date date, started_at timestamptz, seconds integer, limit_seconds integer, burpee_count integer, counted boolean, prior_best integer, points integer)
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT s.id, s.kid_id, s.on_date, s.started_at, s.seconds, s.limit_seconds, s.burpee_count,
         public.family_burpee_counts(s.seconds, s.burpee_count), s.prior_best,
         public.family_burpee_points(s.seconds, s.limit_seconds, s.burpee_count, s.prior_best)
    FROM (SELECT p.id, p.kid_id, p.on_date, p.started_at, p.seconds, p.limit_seconds, p.burpee_count,
                 ceil(round(p.best_pace * p.burpee_count, 6))::int AS prior_best
            FROM (SELECT t.id, t.kid_id, (t.started_at AT TIME ZONE 'America/Chicago')::date AS on_date, t.started_at,
                         t.seconds, t.limit_seconds, t.burpee_count,
                         min(t.seconds::numeric / NULLIF(t.burpee_count, 0))
                           FILTER (WHERE public.family_burpee_counts(t.seconds, t.burpee_count))
                           OVER (PARTITION BY t.kid_id ORDER BY t.started_at, t.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS best_pace
                    FROM public.family_timers t
                   WHERE t.kind = 'burpees' AND t.ended_at IS NOT NULL) p) s
   ORDER BY s.started_at;
$$;

