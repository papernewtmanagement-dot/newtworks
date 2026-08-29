-- Retention floor factor, with the week-over-week improvement kicker.
-- Peter 2026-08-29.
--
-- BASE: factor = 0.50 x (territory median / our lapse rate), auto and fire blended by
-- policies in force, held between 0.25 and 1.00. Worked example in his words: median
-- auto 25%, ours 50% -> take retention's third, cut it in half (the 0.50), then cut it
-- in half again (25/50) -> factor 0.25.
--
-- KICKER: if our lapse improved on the prior week, the rate used for THIS WEEK'S factor
-- gets double the improvement. Ours goes 50% -> 49%, an improvement of 1 point, so the
-- factor is computed as if we were at 48%. The DB still records the real 49%, so if we
-- sit at 49% again next week the improvement is zero and next week is computed at 49%.
-- One-week credit, never a permanent shift. Worsening earns nothing - no penalty, no
-- kicker.
--
-- CEILING: while our RAW rate is worse than the territory median, the kicker can never
-- push the factor past 0.50. Beating the median on the raw number is the only way above
-- half.
--
-- FIX shipped in the same change: this used to read v_lapse_rate_current, which ignores
-- the week asked for and always returns TODAY'S rate - so a past week's factor drifted
-- every day. It now calls compute_lapse_rate for the week in question, and for the week
-- before it. That history is real back to at least 2026-06-27.
CREATE OR REPLACE FUNCTION public.compute_retention_floor_factor(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_med_auto numeric; v_med_fire numeric;
  v_our_auto numeric; v_our_fire numeric;
  v_pif_auto numeric; v_pif_fire numeric;
  v_prior_auto numeric; v_prior_fire numeric;
  v_imp_auto numeric; v_imp_fire numeric;
  v_eff_auto numeric; v_eff_fire numeric;
  v_ratio_auto numeric; v_ratio_fire numeric;
  v_raw_ratio_auto numeric; v_raw_ratio_fire numeric;
  v_blended numeric; v_raw_blended numeric;
  v_factor numeric; v_uncapped numeric; v_half_capped boolean := false;
  v_wt numeric;
BEGIN
  SELECT territory_median_lapse_auto, territory_median_lapse_fire
    INTO v_med_auto, v_med_fire
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  -- our own rate AS OF THIS WEEK (not today)
  SELECT MAX(CASE WHEN line='auto' THEN annualized_rate END),
         MAX(CASE WHEN line='fire' THEN annualized_rate END),
         MAX(CASE WHEN line='auto' THEN starting_pif END),
         MAX(CASE WHEN line='fire' THEN starting_pif END)
    INTO v_our_auto, v_our_fire, v_pif_auto, v_pif_fire
  FROM public.compute_lapse_rate(p_agency_id, p_week_end_date);

  IF v_med_auto IS NULL OR v_med_fire IS NULL
     OR v_our_auto IS NULL OR v_our_fire IS NULL
     OR v_our_auto <= 0 OR v_our_fire <= 0 THEN
    RETURN jsonb_build_object(
      'factor', NULL,
      'reason', 'territory median not entered for this week - no floor applied',
      'median_auto', v_med_auto, 'median_fire', v_med_fire,
      'our_auto', v_our_auto, 'our_fire', v_our_fire);
  END IF;

  -- prior week, same measure
  SELECT MAX(CASE WHEN line='auto' THEN annualized_rate END),
         MAX(CASE WHEN line='fire' THEN annualized_rate END)
    INTO v_prior_auto, v_prior_fire
  FROM public.compute_lapse_rate(p_agency_id, (p_week_end_date - 7));

  -- improvement is a fall in the rate. Only a fall earns anything.
  v_imp_auto := GREATEST(0, COALESCE(v_prior_auto, v_our_auto) - v_our_auto);
  v_imp_fire := GREATEST(0, COALESCE(v_prior_fire, v_our_fire) - v_our_fire);

  -- double the improvement, applied to this week only
  v_eff_auto := GREATEST(0.0001, v_our_auto - (2 * v_imp_auto));
  v_eff_fire := GREATEST(0.0001, v_our_fire - (2 * v_imp_fire));

  v_raw_ratio_auto := v_med_auto / v_our_auto;
  v_raw_ratio_fire := v_med_fire / v_our_fire;
  v_ratio_auto     := v_med_auto / v_eff_auto;
  v_ratio_fire     := v_med_fire / v_eff_fire;

  v_wt := NULLIF(COALESCE(v_pif_auto,0) + COALESCE(v_pif_fire,0), 0);
  v_blended     := (v_ratio_auto     * COALESCE(v_pif_auto,0) + v_ratio_fire     * COALESCE(v_pif_fire,0)) / v_wt;
  v_raw_blended := (v_raw_ratio_auto * COALESCE(v_pif_auto,0) + v_raw_ratio_fire * COALESCE(v_pif_fire,0)) / v_wt;

  v_uncapped := 0.50 * v_blended;
  v_factor := v_uncapped;

  -- raw rate worse than the median => the kicker cannot carry us past half
  IF v_raw_blended < 1.0 AND v_factor > 0.50 THEN
    v_factor := 0.50;
    v_half_capped := true;
  END IF;

  v_factor := LEAST(1.00, GREATEST(0.25, v_factor));

  RETURN jsonb_build_object(
    'factor', ROUND(v_factor,4),
    'blended_ratio', ROUND(v_blended,4),
    'raw_blended_ratio', ROUND(v_raw_blended,4),
    'median_auto', v_med_auto, 'our_auto', ROUND(v_our_auto,4), 'ratio_auto', ROUND(v_ratio_auto,4),
    'median_fire', v_med_fire, 'our_fire', ROUND(v_our_fire,4), 'ratio_fire', ROUND(v_ratio_fire,4),
    'prior_auto', ROUND(v_prior_auto,4), 'prior_fire', ROUND(v_prior_fire,4),
    'improvement_auto', ROUND(v_imp_auto,4), 'improvement_fire', ROUND(v_imp_fire,4),
    'effective_auto', ROUND(v_eff_auto,4), 'effective_fire', ROUND(v_eff_fire,4),
    'kicker_applied', (v_imp_auto > 0 OR v_imp_fire > 0),
    'half_capped', v_half_capped,
    'pif_auto', v_pif_auto, 'pif_fire', v_pif_fire,
    'clamped', v_uncapped <> v_factor,
    'note', 'factor 0.50 = median performance = the plain divide-by-two floor; kicker doubles a week-over-week improvement for that week only');
END;
$function$;