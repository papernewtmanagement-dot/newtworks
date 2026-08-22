-- Step 4 rewire fn #2: assessment_competency_attention_to_detail → v2 signal + 2c comp-side curve.

INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'attention_to_detail',
  55,
  $notes$Floor set at 55 for Attention to Detail competency (LSS Step 4 rewire fn #2).

Rationale:
- Attention-to-detail work involves sustained attention, working-memory maintenance, and cross-checking. Moderate cognitive demand — one notch below Analytical (60) which requires abstract reasoning.
- Salthouse 1996 — attention/vigilance tasks are strongly g-loaded; processing speed underpins verification accuracy.
- Ackerman 1988 — g-loading is heaviest early in tenure; skill accretion partially compensates with expertise.
- Hunter & Hunter 1984 — clerical/verification jobs sit at medium complexity (validity r≈.51).
- Story Agency context: this competency matters most in application submissions, quote accuracy, and compliance documentation — errors here are high-consequence.
- 55 matches the mid-medium role floors (sales_outbound, sales_inbound, retention_reception) and is defensible as "below this intelligence signal, detail work will suffer systematically regardless of conscientiousness."

Citations:
- Salthouse 1996 (Psychological Review 103, 403-428) — processing speed as general cognitive factor
- Ackerman 1988 (Journal of Experimental Psychology: General 117, 288-318) — g-loading × task-familiarity moderation
- Hunter & Hunter 1984 — job complexity taxonomy
- Zhou, Kuncel & Sackett 2024 — "virtually necessary condition" at low ability
- Kane 1996 — measurement precision near cut score
- Sweller 1988 — cognitive load theory; near-floor degradation$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor = EXCLUDED.floor,
    notes = EXCLUDED.notes,
    updated_at = now(),
    updated_by = EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_attention_to_detail(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
Competency: Attention to Detail (LSS Step 4 rewire — v2 signal source, 2c comp-side curve).

Base score: unit-weighted linear composite of personality traits per Wainer 1976 and Ree/Earles/Teachout 1994.
  base = 14.29 + 0.43*analytical + 0.21*deadline_motivation + 0.14*recognition_drive
       + 0.07*independent_spirit - 0.07*optimism - 0.07*self_promotion

LSS penalty: 2c comp-side monotonic floor curve on intelligence composite from hiregauge_lss_delta_v2.
  mult = 1.0                                          if composite >= floor
       = exp(-3.0 * (floor - composite) / floor)      if composite <  floor
Floor lookup: hiregauge_competency_floors WHERE competency_name='attention_to_detail'.

Reliability adjustment: applied around 50 midpoint via _assessment_reliability_confidence (unchanged from v1).

Research citations:
- Ree, Earles & Teachout 1994; Wainer 1976 — unit-weighted composite justification
- Salthouse 1996 — processing speed as general cognitive factor
- Ackerman 1988 — g-loading × task-familiarity moderation
- Hunter & Hunter 1984 — clerical/verification at medium complexity
- Zhou, Kuncel & Sackett 2024 — asymmetric decay near floor
- Kane 1996 — measurement precision near cut score
- Sweller 1988 — cognitive load mechanism for near-floor degradation
- Coward & Sackett 1990 — mid-range empirical linearity caveat; exponential-below-floor is design choice
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
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF an IS NULL THEN
    v_base := NULL;
  ELSE
    v_base := GREATEST(0, LEAST(100, ROUND(
      (14.285714) + (+0.428571)*an + (+0.214286)*dm + (+0.142857)*rd + (+0.071429)*is_val + (-0.071429)*op + (-0.071429)*sp
    )::int));
  END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor
  FROM public.hiregauge_competency_floors
  WHERE agency_id = p_candidate.agency_id AND competency_name = 'attention_to_detail';

  IF v_composite IS NULL OR v_floor IS NULL THEN
    v_mult := 1.0;
  ELSIF v_composite >= v_floor THEN
    v_mult := 1.0;
  ELSE
    v_mult := exp(-3.0 * (v_floor - v_composite) / v_floor);
  END IF;

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
