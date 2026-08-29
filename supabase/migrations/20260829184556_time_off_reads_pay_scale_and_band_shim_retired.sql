-- Retire the sales_points_band_config shim for good.
--
-- The time-off gate only ever wanted one number out of it: the weekly Sales
-- Points where the Good band starts. That is a single pay_scale row, so the
-- lookup goes straight there and no view is needed. My previous migration
-- pointed this function at a view name I had not created — that is corrected
-- here, and the shim is dropped.

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='time_off_check_eligibility';

  v_new := replace(v_def,
$a$      SELECT min_threshold INTO v_good_floor
      FROM public.v_sales_points_bands
      WHERE agency_id = v_team.agency_id AND rating_name = 'Good';$a$,
$b$      -- Where the Good band starts, straight off pay_scale.
      SELECT sales_points INTO v_good_floor
      FROM public.pay_scale
      WHERE agency_id = v_team.agency_id AND role_key = 'sales'
        AND band_starts_here AND band = 'Good'
      LIMIT 1;$b$);

  IF v_new = v_def THEN
    RAISE EXCEPTION 'band lookup not found in time_off_check_eligibility';
  END IF;
  IF v_new LIKE '%v_sales_points_bands%' OR v_new LIKE '%sales_points_band_config%' THEN
    RAISE EXCEPTION 'band shim still referenced';
  END IF;
  EXECUTE v_new;
END
$mig$;

DROP VIEW IF EXISTS public.sales_points_band_config;
