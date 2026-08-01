-- Step 4 rewire fn #3: assessment_competency_balances_logic_and_emotion_when_hiring → v2 signal + 2c curve

INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'balances_logic_and_emotion_when_hiring',
  60,
  $notes$Floor set at 60 for Balances Logic and Emotion when Hiring (LSS Step 4 rewire fn #3).

Rationale:
- Hiring judgment requires reading people, weighing conflicting evidence, catching story inconsistency, and resisting likability bias. High working-memory load + abstract-reasoning demand.
- Hunter & Hunter 1984 places person-perception + evidence-weighing tasks in the professional-managerial band (validity r≈.58).
- Emotional-intelligence overlay adds nuance but does not raise the cognitive-demand floor — g-loaded reasoning is the binding constraint.
- Setting at 60 matches Analytical (60), keeping parity across reasoning-heavy competencies. Slightly below Aspirant role floor (70) which aggregates across many competencies.

Citations:
- Hunter & Hunter 1984 — professional-managerial complexity band
- Judge & Kammeyer-Mueller 2012 — person-perception + interviewer judgment meta-analytic evidence
- Zhou, Kuncel & Sackett 2024 — "virtually necessary condition" at low ability
- Kane 1996; Sweller 1988; Coward & Sackett 1990 — curve shape rationale (same as fn #1)$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor = EXCLUDED.floor,
    notes = EXCLUDED.notes,
    updated_at = now(),
    updated_by = EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_balances_logic_and_emotion_when_hiring(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
Competency: Balances Logic and Emotion when Hiring (LSS Step 4 rewire — v2 signal + 2c curve).

Base score: unit-weighted linear composite of personality traits (Wainer 1976; Ree/Earles/Teachout 1994).
  base = 30 - 0.05*recognition_drive + 0.35*assertiveness + 0.15*analytical + 0.20*independent_spirit
       - 0.15*compassion - 0.10*self_promotion

LSS penalty: 2c monotonic floor curve on intelligence composite from hiregauge_lss_delta_v2.
Floor lookup: hiregauge_competency_floors WHERE competency_name='balances_logic_and_emotion_when_hiring'.

Reliability adjustment: applied around 50 midpoint (unchanged from v1).

Research citations:
- Ree/Earles/Teachout 1994; Wainer 1976 — unit-weighted composite justification
- Hunter & Hunter 1984 — professional-managerial complexity band
- Judge & Kammeyer-Mueller 2012 — person-perception + interviewer judgment
- Zhou/Kuncel/Sackett 2024; Kane 1996; Sweller 1988; Coward/Sackett 1990 — curve shape rationale
- Sheppard/Vernon 2008; Ratcliff 1993; van Zandt 2000 — signal source mechanics (documented in hiregauge_lss_delta_v2)
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
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  an numeric := p_candidate.analytical;
  is_val numeric := p_candidate.independent_spirit;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
BEGIN
  IF ass IS NULL THEN
    v_base := NULL;
  ELSE
    v_base := GREATEST(0, LEAST(100, ROUND(
      (30.000000) + (-0.050000)*rd + (+0.350000)*ass + (+0.150000)*an + (+0.200000)*is_val + (-0.150000)*com + (-0.100000)*sp
    )::int));
  END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor
  FROM public.hiregauge_competency_floors
  WHERE agency_id = p_candidate.agency_id AND competency_name = 'balances_logic_and_emotion_when_hiring';

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
