-- Peter 2026-08-28. Retention floor divisor becomes performance-driven.
-- Two numbers entered weekly on the CPR: territory median lapse for auto and
-- fire. Stored ON the weekly CPR row so they freeze with the week and cannot
-- drift, same discipline as weekly_pool_lock.
--
-- Factor = 0.50 x (territory median / our rate), auto and fire blended by
-- policies in force, clamped 0.25 to 1.00. At median the factor is 0.50, which
-- reproduces the plain "divide by two" floor exactly. Life is excluded per Peter.

ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS territory_median_lapse_auto numeric,
  ADD COLUMN IF NOT EXISTS territory_median_lapse_fire numeric,
  ADD COLUMN IF NOT EXISTS agency_lapse_auto_at_write   numeric,
  ADD COLUMN IF NOT EXISTS agency_lapse_fire_at_write   numeric,
  ADD COLUMN IF NOT EXISTS retention_floor_factor       numeric;

COMMENT ON COLUMN public.weekly_cpr_reports.territory_median_lapse_auto IS
'Peter-entered. Annualized auto lapse/cancel rate of the median agency in territory (rank 25 of 49). Stored per week; never back-filled across weeks.';
COMMENT ON COLUMN public.weekly_cpr_reports.territory_median_lapse_fire IS
'Peter-entered. Annualized fire lapse/cancel rate of the median agency in territory (rank 25 of 49). Stored per week; never back-filled across weeks.';
COMMENT ON COLUMN public.weekly_cpr_reports.retention_floor_factor IS
'Frozen at write time. NULL when either median is missing, and a NULL factor means NO floor is applied that week.';

-- Prefill helper: most recent medians entered before the given week.
CREATE OR REPLACE FUNCTION public.get_prior_territory_medians(
  p_agency_id uuid, p_week_end_date date)
RETURNS TABLE(median_auto numeric, median_fire numeric, sourced_from date)
LANGUAGE sql STABLE AS $$
  SELECT r.territory_median_lapse_auto, r.territory_median_lapse_fire, r.week_ending_date
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = p_agency_id
    AND r.week_ending_date < p_week_end_date
    AND r.territory_median_lapse_auto IS NOT NULL
    AND r.territory_median_lapse_fire IS NOT NULL
  ORDER BY r.week_ending_date DESC
  LIMIT 1;
$$;

-- Factor calculation. Returns NULL factor when a median is missing.
CREATE OR REPLACE FUNCTION public.compute_retention_floor_factor(
  p_agency_id uuid, p_week_end_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_med_auto numeric; v_med_fire numeric;
  v_our_auto numeric; v_our_fire numeric;
  v_pif_auto numeric; v_pif_fire numeric;
  v_ratio_auto numeric; v_ratio_fire numeric; v_blended numeric; v_factor numeric;
BEGIN
  SELECT territory_median_lapse_auto, territory_median_lapse_fire
    INTO v_med_auto, v_med_fire
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  SELECT MAX(CASE WHEN line='auto' THEN annualized_rate END),
         MAX(CASE WHEN line='fire' THEN annualized_rate END),
         MAX(CASE WHEN line='auto' THEN starting_pif END),
         MAX(CASE WHEN line='fire' THEN starting_pif END)
    INTO v_our_auto, v_our_fire, v_pif_auto, v_pif_fire
  FROM public.v_lapse_rate_current WHERE agency_id = p_agency_id;

  IF v_med_auto IS NULL OR v_med_fire IS NULL
     OR v_our_auto IS NULL OR v_our_fire IS NULL
     OR v_our_auto <= 0 OR v_our_fire <= 0 THEN
    RETURN jsonb_build_object(
      'factor', NULL,
      'reason', 'territory median not entered for this week - no floor applied',
      'median_auto', v_med_auto, 'median_fire', v_med_fire,
      'our_auto', v_our_auto, 'our_fire', v_our_fire);
  END IF;

  v_ratio_auto := v_med_auto / v_our_auto;
  v_ratio_fire := v_med_fire / v_our_fire;
  v_blended := (v_ratio_auto * COALESCE(v_pif_auto,0) + v_ratio_fire * COALESCE(v_pif_fire,0))
               / NULLIF(COALESCE(v_pif_auto,0) + COALESCE(v_pif_fire,0), 0);
  v_factor := LEAST(1.00, GREATEST(0.25, 0.50 * v_blended));

  RETURN jsonb_build_object(
    'factor', ROUND(v_factor,4),
    'blended_ratio', ROUND(v_blended,4),
    'median_auto', v_med_auto, 'our_auto', ROUND(v_our_auto,4), 'ratio_auto', ROUND(v_ratio_auto,4),
    'median_fire', v_med_fire, 'our_fire', ROUND(v_our_fire,4), 'ratio_fire', ROUND(v_ratio_fire,4),
    'pif_auto', v_pif_auto, 'pif_fire', v_pif_fire,
    'clamped', (0.50 * v_blended) <> v_factor,
    'note', 'factor 0.50 = median performance = the plain divide-by-two floor');
END;
$$;

