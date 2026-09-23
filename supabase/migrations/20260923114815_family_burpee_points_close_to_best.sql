-- Burpee points, Peter 2026-09-23: 5 beats your own best, 3 within 10% of your own
-- best, 2 in half the time or less, 1 under the limit, 0 over the limit or quicker
-- than 1.5 seconds a burpee. Highest tier only. Every caller (the stop, the week's
-- points, the champion) reads this one function.
CREATE OR REPLACE FUNCTION public.family_burpee_points(p_seconds integer, p_limit integer, p_count integer, p_prior_best integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_seconds IS NULL OR p_limit IS NULL OR p_seconds > p_limit THEN 0
    WHEN NOT public.family_burpee_counts(p_seconds, p_count) THEN 0
    WHEN p_prior_best IS NOT NULL AND p_seconds < p_prior_best THEN 5
    WHEN p_prior_best IS NOT NULL AND p_seconds <= p_prior_best * 1.1 THEN 3
    WHEN p_seconds * 2 <= p_limit THEN 2
    ELSE 1 END;
$$;

