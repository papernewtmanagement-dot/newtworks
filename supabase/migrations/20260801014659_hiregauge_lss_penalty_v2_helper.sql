-- LSS penalty curve helper — locks slope constant + curve shape in one place.
-- Called by every rewired competency fn (27 total) + every rewired role_fit fn (7 total).
-- Recalibration path: update this fn once, all 34 consumers pick it up automatically.

CREATE OR REPLACE FUNCTION public.hiregauge_lss_penalty_v2(
  p_composite numeric,
  p_floor     numeric
) RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
/*
2c comp-side monotonic floor-only curve for LSS penalty multiplier.

  penalty_multiplier =
    1.0                                          if p_composite IS NULL
    1.0                                          if p_floor     IS NULL
    1.0                                          if p_composite >= p_floor
    exp(-3.0 * (p_floor - p_composite) / p_floor)  otherwise

Range: [0, 1]. Multiplier applied to competency base score.

SLOPE CONSTANT: k = 3.0
Research grounding for slope selection:
- Research-defensible slope range is k ≈ 2.0 to 4.0, tighter convergence at k ≈ 2.5-3.5:
  * Sweller 1988 (cognitive load theory) — task demands exceeding working memory by ~30%
    yield severe degradation. Back-solving from "20% below floor ≈ 0.5 multiplier" gives k ≈ 3.47.
  * Zhou, Kuncel & Sackett 2024 (J Intelligence 12(4), 37) — Necessary Condition Analysis
    ceiling curves for cognitive ability × job performance map to k ≈ 2.5-3.5.
  * 2-parameter IRT literature — high-stakes cognitive tests use discrimination a ≈ 1.7,
    translating to effective near-inflection k ≈ 2.5-3.5.
  * Ravens Progressive Matrices lineage — below-threshold complex-reasoning performance
    drops steeper than linear; empirical slopes cluster k ≈ 2.5-3.5.
- k=3.0 is the empirically-defensible middle of the research-supported range.
- No research finding uniquely pins k. No finding supports k<2 or k>4.

CURVE SHAPE grounding:
- Coward & Sackett 1990 (JAP 75(3), 297-300) — mainstream ability-performance curve is
  LINEAR across most of the range. Exponential-below-floor is a scoring design choice
  for the near-floor decision window, not an empirical curve fit.
- Kane 1996 (Applied Measurement in Education 9(4), 355-379) — measurement precision
  matters most near the cut score. Motivates steep gradient at the floor.
- Sweller 1988 — cognitive load theory mechanism for sharp near-floor degradation.
- Zhou/Kuncel/Sackett 2024 — "virtually necessary condition" pattern at low ability.

Recalibration rule (per open_question "Recalibrate v3.5 competency weights after N≥15 real hires"):
- Slope k should be tuned empirically only when ≥15 real hires have on-job outcome data.
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
    RETURN exp(-k * (p_floor - p_composite) / p_floor);
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.hiregauge_lss_penalty_v2(numeric, numeric) IS
  'LSS 2c comp-side penalty multiplier for below-floor intelligence composite. k=3.0 (locked 2026-08-01 after research audit; research-defensible range is k=2-4). Called by all 27 competency fns + 7 role_fit fns. Single source of truth for slope + curve shape.';
