-- Peter 2026-08-28, the last of the pay-table consolidation.
--
-- 1. expected_team_bonus_annual_y1 dropped. Added and deprecated the same
--    day for a two-window bonus design Peter rejected; nothing has written
--    or read it since.
--
-- 2. mvp_draw_tiers folded in as pay_scale.mvp_draws and dropped. It held
--    three rows: 100 / 300 / 500 new Sales Points for 1 / 2 / 3 prize-cart
--    draws. NOTE the thresholds do not line up with the bands (which start
--    at 50 / 150 / 300 / 500) — that mismatch was flagged in an earlier
--    thread and is preserved exactly as it was, not quietly resolved.
--
-- 3. sales_points_band_config folded in and dropped. Every pay_scale row
--    already carries its band name, so the band boundaries were duplicated.
--    compute_sales_points_rating now reads the bands off pay_scale.
--    The two other callers compare band NAMES, which have not changed, so
--    they keep working untouched.
--
--    Circularity: reseed_pay_scale used to call compute_sales_points_rating
--    while rebuilding pay_scale, which would now read the table it is
--    mid-rebuild. reseed therefore captures the band boundaries up front
--    and assigns the band from that capture instead of calling out.

ALTER TABLE public.pay_scale DROP COLUMN IF EXISTS expected_team_bonus_annual_y1;

ALTER TABLE public.pay_scale ADD COLUMN IF NOT EXISTS mvp_draws int;
COMMENT ON COLUMN public.pay_scale.mvp_draws IS
  'Prize-cart draws earned at this weekly Sales Points level. Set on the row where the draw count steps up. These thresholds (100/300/500) deliberately do NOT match the band boundaries (50/150/300/500) — that difference predates the consolidation.';

UPDATE public.pay_scale p SET mvp_draws = v.n
  FROM (VALUES (100,1),(300,2),(500,3)) AS v(fx, n)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales' AND p.sales_points = v.fx;

DROP TABLE IF EXISTS public.mvp_draw_tiers;

ALTER TABLE public.pay_scale ADD COLUMN IF NOT EXISTS band_starts_here boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.pay_scale.band_starts_here IS
  'True on the lowest row of each band. Those rows define the band boundaries that compute_sales_points_rating reads.';

UPDATE public.pay_scale p SET band_starts_here = true
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales'
   AND p.sales_points IN (
     SELECT MIN(q.sales_points) FROM public.pay_scale q
      WHERE q.agency_id = p.agency_id AND q.role_key = 'sales' AND q.band IS NOT NULL
      GROUP BY q.band);

CREATE OR REPLACE FUNCTION public.compute_sales_points_rating(p_agency_id uuid, p_value numeric)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Bands live on pay_scale now: the rows flagged band_starts_here are the
  -- boundaries. Highest boundary at or below the value wins.
  SELECT p.band
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id
     AND p.role_key = 'sales'
     AND p.band_starts_here
     AND p.sales_points <= COALESCE(p_value, 0)
   ORDER BY p.sales_points DESC
   LIMIT 1;
$function$;

-- reseed: capture the band boundaries and the draw counts, assign the band
-- inline, and restore both afterwards.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='reseed_pay_scale';
  v_new := v_def;

  v_new := replace(v_new, $a$  v_bandkeep jsonb;$a$,
                          $b$  v_bandkeep jsonb;
  v_bounds   jsonb;
  v_draws    jsonb;$b$);

  v_new := replace(v_new,
    $a$  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);$a$,
    $b$  SELECT COALESCE(jsonb_agg(jsonb_build_object('fx', p.sales_points, 'band', p.band)
                                ORDER BY p.sales_points), '[]'::jsonb)
    INTO v_bounds
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.band_starts_here;

  SELECT COALESCE(jsonb_object_agg(p.sales_points::text, p.mvp_draws), '{}'::jsonb)
    INTO v_draws
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.mvp_draws IS NOT NULL;

  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);$b$);

  -- Band comes from the captured boundaries, not from a call into the table
  -- being rebuilt.
  v_new := replace(v_new,
    $a$      public.compute_sales_points_rating(p_agency_id, v_x),$a$,
    $b$      (SELECT e->>'band' FROM jsonb_array_elements(v_bounds) e
        WHERE (e->>'fx')::int <= v_x ORDER BY (e->>'fx')::int DESC LIMIT 1),$b$);

  v_new := replace(v_new,
    $a$  -- Put the band annotations back onto their band-start rows.$a$,
    $b$  -- Restore the band boundary flags and the prize-cart draw counts.
  UPDATE public.pay_scale t SET band_starts_here = true
    FROM jsonb_array_elements(v_bounds) e
   WHERE t.agency_id = p_agency_id AND t.role_key = 'sales'
     AND t.sales_points = (e->>'fx')::int;

  UPDATE public.pay_scale t SET mvp_draws = (v_draws->>t.sales_points::text)::int
   WHERE t.agency_id = p_agency_id AND t.role_key = 'sales'
     AND v_draws ? t.sales_points::text;

  -- Put the band annotations back onto their band-start rows.$b$);

  IF v_new NOT LIKE '%v_bounds%' OR v_new LIKE '%public.compute_sales_points_rating(p_agency_id, v_x)%' THEN
    RAISE EXCEPTION 'reseed band capture not wired';
  END IF;
  EXECUTE v_new;
END
$mig$;

DROP TABLE IF EXISTS public.sales_points_band_config;
