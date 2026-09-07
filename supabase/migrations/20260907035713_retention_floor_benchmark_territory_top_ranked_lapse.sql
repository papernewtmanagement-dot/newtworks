-- Retention floor benchmark: territory TOP-RANKED lapse/cancel rate instead of the territory
-- median (Peter 2026-09-06 -- the top-ranked number is the one he can actually pull each week).
--
-- Scale re-anchored to the new benchmark. With the median, "at the benchmark" earned half the
-- third (factor 0.50). The territory's best agency runs well under the median, so keeping the
-- 0.50 multiplier would have pinned the factor at the 0.25 clamp almost every week and killed
-- the gradient. Now: matching the territory's best keeps the whole third (1.00); twice their
-- lapse rate earns half (0.50); four times earns the 0.25 floor. Clamp 0.25-1.00 unchanged.
-- Improvement kicker unchanged (doubled improvement measured from the prior rate, this week
-- only). The old "held at 0.50 while worse than the benchmark" ceiling is subsumed by the 1.00
-- clamp: only beating the best on the raw rate could ever go above the whole third.
--
-- Weeks with no top-ranked entry fall back to the median math exactly as before, so nothing
-- already computed changes until the new numbers are typed in. Both column pairs stay on the
-- row so historical weeks keep their record.

ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS territory_top_lapse_auto numeric,
  ADD COLUMN IF NOT EXISTS territory_top_lapse_fire numeric;

COMMENT ON COLUMN public.weekly_cpr_reports.territory_top_lapse_auto IS
  'Territory top-ranked (best) auto lapse/cancel rate for the week, as a rate (0.15 not 15). Hand-entered on the CPR page. Drives the retention floor factor; NULL with the fire value NULL = fall back to the median columns, and if those are NULL too = no floor.';
COMMENT ON COLUMN public.weekly_cpr_reports.territory_top_lapse_fire IS
  'Territory top-ranked (best) fire lapse/cancel rate for the week, as a rate. See territory_top_lapse_auto.';

CREATE OR REPLACE FUNCTION public.get_prior_territory_top_lapse(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(top_auto numeric, top_fire numeric, sourced_from date)
 LANGUAGE sql
 STABLE
AS $function$
  SELECT r.territory_top_lapse_auto, r.territory_top_lapse_fire, r.week_ending_date
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = p_agency_id
    AND r.week_ending_date < p_week_end_date
    AND r.territory_top_lapse_auto IS NOT NULL
    AND r.territory_top_lapse_fire IS NOT NULL
  ORDER BY r.week_ending_date DESC
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.compute_retention_floor_factor(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_top_auto numeric; v_top_fire numeric;
  v_med_auto numeric; v_med_fire numeric;
  v_bench_auto numeric; v_bench_fire numeric;
  v_basis text;            -- 'top_ranked' or 'median'
  v_par numeric;           -- factor earned at the benchmark: 1.00 top-ranked, 0.50 median
  v_our_auto numeric; v_our_fire numeric;
  v_pif_auto numeric; v_pif_fire numeric;
  v_prior_auto numeric; v_prior_fire numeric;
  v_imp_auto numeric; v_imp_fire numeric;
  v_eff_auto numeric; v_eff_fire numeric;
  v_ratio_auto numeric; v_ratio_fire numeric;
  v_raw_ratio_auto numeric; v_raw_ratio_fire numeric;
  v_blended numeric; v_raw_blended numeric;
  v_factor numeric; v_uncapped numeric; v_par_capped boolean := false;
  v_wt numeric;
BEGIN
  SELECT territory_top_lapse_auto, territory_top_lapse_fire,
         territory_median_lapse_auto, territory_median_lapse_fire
    INTO v_top_auto, v_top_fire, v_med_auto, v_med_fire
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  -- Benchmark: top-ranked when entered for the week, else the older median entry.
  IF v_top_auto IS NOT NULL AND v_top_fire IS NOT NULL THEN
    v_bench_auto := v_top_auto; v_bench_fire := v_top_fire; v_basis := 'top_ranked'; v_par := 1.00;
  ELSE
    v_bench_auto := v_med_auto; v_bench_fire := v_med_fire; v_basis := 'median'; v_par := 0.50;
  END IF;

  -- our own rate AS OF THIS WEEK (not today)
  SELECT MAX(CASE WHEN line='auto' THEN annualized_rate END),
         MAX(CASE WHEN line='fire' THEN annualized_rate END),
         MAX(CASE WHEN line='auto' THEN starting_pif END),
         MAX(CASE WHEN line='fire' THEN starting_pif END)
    INTO v_our_auto, v_our_fire, v_pif_auto, v_pif_fire
  FROM public.compute_lapse_rate(p_agency_id, p_week_end_date);

  IF v_bench_auto IS NULL OR v_bench_fire IS NULL
     OR v_our_auto IS NULL OR v_our_fire IS NULL
     OR v_our_auto <= 0 OR v_our_fire <= 0 THEN
    RETURN jsonb_build_object(
      'factor', NULL,
      'reason', 'territory top-ranked lapse not entered for this week - no floor applied',
      'basis', v_basis,
      'benchmark_auto', v_bench_auto, 'benchmark_fire', v_bench_fire,
      'median_auto', v_med_auto, 'median_fire', v_med_fire,
      'top_auto', v_top_auto, 'top_fire', v_top_fire,
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

  -- doubled improvement measured from the PRIOR rate: prior - 2*imp, which equals ours - imp
  v_eff_auto := GREATEST(0.0001, v_our_auto - v_imp_auto);
  v_eff_fire := GREATEST(0.0001, v_our_fire - v_imp_fire);

  v_raw_ratio_auto := v_bench_auto / v_our_auto;
  v_raw_ratio_fire := v_bench_fire / v_our_fire;
  v_ratio_auto     := v_bench_auto / v_eff_auto;
  v_ratio_fire     := v_bench_fire / v_eff_fire;

  v_wt := NULLIF(COALESCE(v_pif_auto,0) + COALESCE(v_pif_fire,0), 0);
  v_blended     := (v_ratio_auto     * COALESCE(v_pif_auto,0) + v_ratio_fire     * COALESCE(v_pif_fire,0)) / v_wt;
  v_raw_blended := (v_raw_ratio_auto * COALESCE(v_pif_auto,0) + v_raw_ratio_fire * COALESCE(v_pif_fire,0)) / v_wt;

  v_uncapped := v_par * v_blended;
  v_factor := v_uncapped;

  -- raw rate worse than the benchmark => the kicker cannot carry us past par
  IF v_raw_blended < 1.0 AND v_factor > v_par THEN
    v_factor := v_par;
    v_par_capped := true;
  END IF;

  v_factor := LEAST(1.00, GREATEST(0.25, v_factor));

  RETURN jsonb_build_object(
    'factor', ROUND(v_factor,4),
    'basis', v_basis,
    'par', v_par,
    'blended_ratio', ROUND(v_blended,4),
    'raw_blended_ratio', ROUND(v_raw_blended,4),
    'benchmark_auto', v_bench_auto, 'benchmark_fire', v_bench_fire,
    'top_auto', v_top_auto, 'top_fire', v_top_fire,
    'median_auto', v_med_auto, 'median_fire', v_med_fire,
    'our_auto', ROUND(v_our_auto,4), 'ratio_auto', ROUND(v_ratio_auto,4),
    'our_fire', ROUND(v_our_fire,4), 'ratio_fire', ROUND(v_ratio_fire,4),
    'prior_auto', ROUND(v_prior_auto,4), 'prior_fire', ROUND(v_prior_fire,4),
    'improvement_auto', ROUND(v_imp_auto,4), 'improvement_fire', ROUND(v_imp_fire,4),
    'effective_auto', ROUND(v_eff_auto,4), 'effective_fire', ROUND(v_eff_fire,4),
    'kicker_applied', (v_imp_auto > 0 OR v_imp_fire > 0),
    'half_capped', v_par_capped,
    'par_capped', v_par_capped,
    'pif_auto', v_pif_auto, 'pif_fire', v_pif_fire,
    'clamped', v_uncapped <> v_factor,
    'note', CASE WHEN v_basis = 'top_ranked'
                 THEN 'factor = territory top-ranked lapse / ours (blended by policies in force), held 0.25-1.00. 1.00 = matching the best in the territory keeps the whole third; twice their lapse rate = half. Kicker doubles a week-over-week improvement for that week only.'
                 ELSE 'factor 0.50 = median performance = the plain divide-by-two floor; kicker doubles a week-over-week improvement for that week only (median fallback: no top-ranked entry this week)' END);
END;
$function$;
