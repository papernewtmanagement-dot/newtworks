-- Point the projection's raise_ladder at the new helper so there is one
-- copy of the ladder shape (threshold + measurement window), rather than
-- the grid-rounded version the projection built inline.

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
