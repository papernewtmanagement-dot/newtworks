-- Step 4 rewire fn #1: assessment_competency_analytical → v2 signal + 2c comp-side curve.

-- (a) Seed analytical floor
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'analytical',
  60,
  $notes$Floor set at 60 for Analytical competency (LSS Step 4 rewire fn #1).

Rationale:
- Analytical work sits at top of medium-complexity band per Hunter & Hunter 1984 (validity r≈.51-.58).
- Role floors set in Step 3 span 55-62 for medium-complexity roles. Analytical as a competency lands inside that band, slightly above mid-medium at 60.
- Against the 48-candidate v1+CTS cohort (composite mean 76.9, range 39.8-100), floor=60 penalizes roughly the bottom quartile — the near-floor decision window where Kane 1996 argues measurement precision matters most.

Citations:
- Hunter & Hunter 1984 — job complexity taxonomy; analytical work at top of medium band
- Vinchur, Schippmann, Switzer & Roth 1998 — cognitive-ability meta-analysis for sales
- Zhou, Kuncel & Sackett 2024 (J Intelligence 12(4), 37) — "virtually necessary condition" at low ability; empirical support for asymmetric decay near floor
- Kane 1996 (Applied Measurement in Education 9(4), 355-379) — measurement precision matters most near cut score; motivates steeper near-floor gradient
- Sweller 1988 (Cognitive Science 12(2), 257-285) — cognitive load theory mechanism for sharp degradation when demands exceed working memory
- Coward & Sackett 1990 — mid-range empirical linearity caveat; exponential-below-floor is a scoring design choice for near-floor decision precision, not a claim about empirical curve shape$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor = EXCLUDED.floor,
    notes = EXCLUDED.notes,
    updated_at = now(),
    updated_by = EXCLUDED.updated_by;

-- (b) Rewrite fn body: v2 signal source + 2c curve, base logic + reliability adjustment unchanged
CREATE OR REPLACE FUNCTION public.assessment_competency_analytical(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
Competency: Analytical (LSS Step 4 rewire — v2 signal source, 2c comp-side curve).

Base score: unit-weighted linear composite of personality traits per Wainer 1976 and Ree/Earles/Teachout 1994.
  base = 15 + 0.70*analytical + 0.15*independent_spirit - 0.10*self_promotion - 0.05*belief_in_others

LSS penalty: 2c comp-side monotonic floor curve on intelligence composite from hiregauge_lss_delta_v2.
  mult = 1.0                                          if composite >= floor
       = exp(-3.0 * (floor - composite) / floor)      if composite <  floor
Floor lookup: hiregauge_competency_floors WHERE competency_name='analytical'.

Reliability adjustment: applied around 50 midpoint via _assessment_reliability_confidence
(unchanged from v1). Post-LSS score above 50 gets confidence-weighted; below 50 stays raw.

Research citations:
- Ree, Earles & Teachout 1994 — g plus almost nothing; unit-weighted composite justification
- Wainer 1976 — unit-weighted composites within measurement error of optimal at moderate N
- Hunter & Hunter 1984 — job complexity taxonomy; analytical at top of medium band
- Vinchur, Schippmann, Switzer & Roth 1998 — cognitive-ability meta-analysis for sales
- Zhou, Kuncel & Sackett 2024 — "virtually necessary condition" at low ability; asymmetric decay near floor
- Kane 1996 (Applied Measurement in Education 9(4), 355-379) — measurement precision near cut score
- Sweller 1988 — cognitive load theory; mechanism for sharp near-floor degradation
- Coward & Sackett 1990 — mid-range empirical linearity caveat; exponential-below-floor is a design choice
- Sheppard & Vernon 2008; Ratcliff 1993; van Zandt 2000 — signal source mechanics (documented in hiregauge_lss_delta_v2)
*/
DECLARE
  v_base int;
  v_lss_result jsonb;
  v_composite numeric;
  v_floor numeric;
  v_mult numeric;
  v_pre_rel numeric;
  v_rel_factor numeric;
  v_adjusted int;
  v_delta numeric;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  bo numeric := public._assessment_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
BEGIN
  -- Base score (unchanged from v1)
  IF an IS NULL THEN
    v_base := NULL;
  ELSE
    v_base := GREATEST(0, LEAST(100, ROUND(
      (15.000000) + (0.700000)*an + (0.150000)*is_val + (-0.100000)*sp + (-0.050000)*bo
    )::int));
  END IF;

  -- LSS signal via v2 (drops v1's weight/threshold args; v2 owns those internally)
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  -- Floor lookup (Step 2c monotonic floor-only curve)
  SELECT floor INTO v_floor
  FROM public.hiregauge_competency_floors
  WHERE agency_id = p_candidate.agency_id AND competency_name = 'analytical';

  IF v_composite IS NULL OR v_floor IS NULL THEN
    v_mult := 1.0;
  ELSIF v_composite >= v_floor THEN
    v_mult := 1.0;
  ELSE
    v_mult := exp(-3.0 * (v_floor - v_composite) / v_floor);
  END IF;

  -- Apply LSS multiplier + reliability confidence (preserves v1 midpoint semantics)
  IF v_base IS NULL THEN
    v_adjusted := NULL;
    v_delta := 0;
  ELSE
    v_pre_rel := v_base * v_mult;
    v_delta := v_pre_rel - v_base;
    v_rel_factor := COALESCE(public._assessment_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE
      v_adjusted := GREATEST(0, LEAST(100, ROUND(v_pre_rel)))::int;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'base',           v_base,
    'adjusted',       v_adjusted,
    'delta',          v_delta,
    'composite',      v_composite,
    'floor',          v_floor,
    'lss_multiplier', v_mult,
    'components',     v_lss_result
  );
END;
$function$;
