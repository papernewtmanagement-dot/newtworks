-- Peter 2026-08-28, correcting what the Earning Potential page publishes
-- about raises. The qualifying rule was settled in the "*Raise System" and
-- "*Raise System 2" threads and is NOT "hold the bar for a quarter":
--
--   Tiers 1-4 (year one): the average over the person's ENTIRE tenure to
--   date, checked at each quarter close -- so over 1 quarter, then 2, then
--   3, then 4. The window grows with tenure.
--   Tiers 5-12 (after year one): a rolling average of the prior four
--   quarters, checked at every quarter close.
--   One tier per quarter close, in order. Reviews happen only at quarter
--   close, same day for everyone.
--
-- The page was also publishing the wrong numbers. pay_scale is a 10-point
-- grid, so a threshold of 425 first appears on the 430 row and the card
-- showed 430. The real thresholds live in pay_scale.next_raise_at, which
-- reseed_pay_scale writes unrounded. The ladder now reads the threshold off
-- the previous tier's next_raise_at, so the published number is the policy
-- number: 100, 175, 250, 300, 325, 355, 390, 425, 460, 500, 545, 595.
--
-- Those post-year-one thresholds rise about 9% a tier by design -- each
-- raise is meant to be harder than the last. Flat point steps were tried
-- and rejected for making the ladder easier as it climbs.

CREATE OR REPLACE FUNCTION public.earnings_raise_ladder(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_agg(jsonb_build_object(
           'tier', z.tier,
           'hourly', z.hourly,
           'threshold', z.threshold,
           'from_x', z.fx,
           'base_annual', round(z.hourly * 2080, 0),
           'window_kind', CASE WHEN z.tier = 0 THEN 'start'
                               WHEN z.tier <= 4 THEN 'tenure'
                               ELSE 'rolling' END,
           'window_quarters', CASE WHEN z.tier = 0 THEN NULL
                                   WHEN z.tier <= 4 THEN z.tier
                                   ELSE 4 END
         ) ORDER BY z.tier)
    FROM (
      SELECT g.tier, g.hourly, g.fx,
             LAG(g.next_at) OVER (ORDER BY g.tier) AS threshold
        FROM (SELECT p.raise_tier AS tier,
                     MIN(p.base_hourly)   AS hourly,
                     MIN(p.sales_points)  AS fx,
                     MIN(p.next_raise_at) AS next_at
                FROM public.pay_scale p
               WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
               GROUP BY p.raise_tier) g
    ) z;
$function$;
