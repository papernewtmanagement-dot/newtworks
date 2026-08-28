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

-- Point the projection's raise_ladder at the helper so there is one copy of
-- the ladder shape, rather than the grid-rounded version it built inline.
DO $mig$
DECLARE
  v_def text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'compute_role_earnings_projection';

  v_new := replace(v_def,
$old$        -- The published raise ladder, read back off the one copy of it.
        SELECT jsonb_agg(jsonb_build_object(
                 'tier', z.tier, 'hourly', z.hourly, 'from_x', z.fx,
                 'base_annual', round(z.hourly * 2080, 0)
               ) ORDER BY z.fx)
          INTO v_ladder
          FROM (SELECT p.base_hourly AS hourly, MIN(p.sales_points) AS fx, MIN(p.raise_tier) AS tier
                  FROM public.pay_scale p
                 WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
                 GROUP BY p.base_hourly) z;$old$,
$new$        -- The published raise ladder, with its real thresholds and the
        -- window each tier is measured over. One copy, in
        -- public.earnings_raise_ladder.
        v_ladder := public.earnings_raise_ladder(p_agency_id);$new$);

  IF v_new = v_def THEN
    RAISE EXCEPTION 'raise ladder block not found in compute_role_earnings_projection';
  END IF;
  IF v_new NOT LIKE '%public.earnings_raise_ladder(p_agency_id)%' THEN
    RAISE EXCEPTION 'replacement did not take';
  END IF;

  EXECUTE v_new;
END
$mig$;
