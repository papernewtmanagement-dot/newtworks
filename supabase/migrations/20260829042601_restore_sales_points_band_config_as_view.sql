-- FIX: dropping sales_points_band_config broke the Earning Potential page.
-- I checked its consumers before folding the bands into pay_scale, but two
-- references were added or missed afterwards and I did not re-check:
--   compute_role_earnings_projection reads it to work out where the band
--     pattern ends (the 750 edge of the chart) — that is the page error;
--   time_off_check_eligibility reads it directly as well, not only through
--     compute_sales_points_rating, so the time-off gate was broken too.
--
-- The name comes back as a VIEW over pay_scale, so there is still one copy
-- of the band boundaries and every existing caller keeps working unchanged.
-- The projection is additionally pointed straight at pay_scale.

CREATE OR REPLACE VIEW public.sales_points_band_config
WITH (security_invoker = true) AS
SELECT b.agency_id,
       b.band                                   AS rating_name,
       CASE WHEN b.rn = 1 THEN NULL ELSE b.sales_points END::numeric AS min_threshold,
       b.next_start::numeric                    AS max_threshold,
       b.rn                                     AS display_order
  FROM (
    SELECT p.agency_id, p.band, p.sales_points,
           ROW_NUMBER() OVER (PARTITION BY p.agency_id ORDER BY p.sales_points) AS rn,
           LEAD(p.sales_points) OVER (PARTITION BY p.agency_id ORDER BY p.sales_points) AS next_start
      FROM public.pay_scale p
     WHERE p.role_key = 'sales' AND p.band_starts_here
  ) b;

COMMENT ON VIEW public.sales_points_band_config IS
  'Band boundaries as the old table exposed them, derived from the pay_scale rows flagged band_starts_here. Kept so existing callers (time_off_check_eligibility among them) keep working; pay_scale remains the one copy.';

GRANT SELECT ON public.sales_points_band_config TO anon, authenticated;

-- Point the projection straight at pay_scale rather than through the shim.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='compute_role_earnings_projection';
  v_new := v_def;

  v_new := replace(v_new,
$a$  SELECT COUNT(*) INTO v_band_n
    FROM public.sales_points_band_config WHERE agency_id = p_agency_id;
  SELECT b.max_threshold INTO v_danger_w
    FROM public.sales_points_band_config b
   WHERE b.agency_id = p_agency_id ORDER BY b.display_order LIMIT 1;
  SELECT b.min_threshold INTO v_top_start
    FROM public.sales_points_band_config b
   WHERE b.agency_id = p_agency_id ORDER BY b.display_order DESC LIMIT 1;$a$,
$b$  SELECT COUNT(*) INTO v_band_n
    FROM public.pay_scale b
   WHERE b.agency_id = p_agency_id AND b.role_key = 'sales' AND b.band_starts_here;
  -- Danger's width is where the second band begins.
  SELECT b.sales_points INTO v_danger_w
    FROM public.pay_scale b
   WHERE b.agency_id = p_agency_id AND b.role_key = 'sales' AND b.band_starts_here
     AND b.sales_points > 0
   ORDER BY b.sales_points LIMIT 1;
  SELECT b.sales_points INTO v_top_start
    FROM public.pay_scale b
   WHERE b.agency_id = p_agency_id AND b.role_key = 'sales' AND b.band_starts_here
   ORDER BY b.sales_points DESC LIMIT 1;$b$);

  IF v_new LIKE '%sales_points_band_config%' THEN
    RAISE EXCEPTION 'projection still reads the band shim';
  END IF;
  EXECUTE v_new;
END
$mig$;
