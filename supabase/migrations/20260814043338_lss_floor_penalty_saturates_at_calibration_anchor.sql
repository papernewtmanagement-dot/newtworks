-- Companion to role_fit_v5_2_pool_normed_cognitive_inputs (same session). The
-- exponential below-floor curve was designed, per its own docstring, for the
-- "near-floor decision window" and calibrated to "20% below floor ~= 0.5 multiplier".
-- Under the old (uncorrected) input scale, gma ran 63-94 against floors 50-70, so
-- shortfalls never exceeded ~7 points and the curve operated only in its designed
-- window. With truly scaled inputs (pool percentiles ~1-99), shortfalls up to ~50
-- points fed the unbounded exponential and produced multipliers near 0.05 --
-- obliterating fit scores rather than informing them, and double-counting low ability:
-- the pool-percentile gma input now drags the weighted sum down LINEARLY across the
-- whole range, which is the empirically supported shape (Coward & Sackett 1990 JAP
-- 75:297-300 -- linear ability-performance -- already cited by this function as the
-- reason the exponential is a near-floor design choice, not an empirical curve).
-- Fix: the multiplier saturates at 0.5 -- the function's own documented calibration
-- anchor -- so behavior inside the designed window (shortfall <= 20% of floor) is
-- byte-identical, and beyond it the deep-shortfall signal is carried by the linear
-- input in the sum instead of by unbounded multiplicative compounding. Slope k and the
-- >=15-hires recalibration rule unchanged.

CREATE OR REPLACE FUNCTION public.hiregauge_lss_penalty_v2(p_composite numeric, p_floor numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
/*
2c comp-side monotonic floor-only curve for LSS penalty multiplier.

  penalty_multiplier =
    1.0                                                            if p_composite IS NULL
    1.0                                                            if p_floor     IS NULL
    1.0                                                            if p_composite >= p_floor
    GREATEST(0.5, exp(-3.0 * (p_floor - p_composite) / p_floor))   otherwise

Range: [0.5, 1]. Multiplier applied to the role-fit base score.

SATURATION AT 0.5 (added 2026-08-14, role_fit_v5_2 companion): the exponential is a
scoring design choice for the NEAR-FLOOR decision window (see curve-shape grounding
below), calibrated to "20% below floor ~= 0.5". With v5.2's truly scaled inputs (pool
percentiles), shortfalls far beyond that window occur and the low-ability signal is
already carried linearly by the gma input inside the weighted sum (Coward & Sackett
1990 -- linear ability-performance). The multiplier therefore saturates at its own
calibration anchor: identical inside the designed window, no unbounded compounding
beyond it, no double-counting of deep shortfalls.

SLOPE CONSTANT: k = 3.0
Research grounding for slope selection:
- Research-defensible slope range is k ~= 2.0 to 4.0, tighter convergence at k ~= 2.5-3.5:
  * Sweller 1988 (cognitive load theory) -- task demands exceeding working memory by ~30%
    yield severe degradation. Back-solving from "20% below floor ~= 0.5 multiplier" gives k ~= 3.47.
  * Zhou, Kuncel & Sackett 2024 (J Intelligence 12(4), 37) -- Necessary Condition Analysis
    ceiling curves for cognitive ability x job performance map to k ~= 2.5-3.5.
  * 2-parameter IRT literature -- high-stakes cognitive tests use discrimination a ~= 1.7,
    translating to effective near-inflection k ~= 2.5-3.5.
  * Ravens Progressive Matrices lineage -- below-threshold complex-reasoning performance
    drops steeper than linear; empirical slopes cluster k ~= 2.5-3.5.
- k=3.0 is the empirically-defensible middle of the research-supported range.
- No research finding uniquely pins k. No finding supports k<2 or k>4.

CURVE SHAPE grounding:
- Coward & Sackett 1990 (JAP 75(3), 297-300) -- mainstream ability-performance curve is
  LINEAR across most of the range. Exponential-below-floor is a scoring design choice
  for the near-floor decision window, not an empirical curve fit.
- Kane 1996 (Applied Measurement in Education 9(4), 355-379) -- measurement precision
  matters most near the cut score. Motivates steep gradient at the floor.
- Sweller 1988 -- cognitive load theory mechanism for sharp near-floor degradation.
- Zhou/Kuncel/Sackett 2024 -- "virtually necessary condition" pattern at low ability.

Recalibration rule:
- Slope k should be tuned empirically only when >=15 real hires have on-job outcome data.
- Do not tune based on candidate scores from the pre-outcome cohort.
*/
DECLARE
  k CONSTANT numeric := 3.0;
BEGIN
  IF p_composite IS NULL OR p_floor IS NULL THEN
    RETURN 1.0;
  ELSIF p_composite >= p_floor THEN
    RETURN 1.0;
  ELSE
    RETURN GREATEST(0.5, exp(-k * (p_floor - p_composite) / p_floor));
  END IF;
END;
$function$;
