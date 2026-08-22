INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'dials_cold_calls',
  35,
  $notes$Floor set at 35 for Dials Cold Calls (LSS Step 4 rewire fn #8).

Rationale:
- Pure activity + persistence competency. Base formula: deadline_motivation (0.26) + assertiveness (0.21) + optimism (0.16) as top weights. Analytical AND compassion have NEGATIVE weights — over-thinking and rejection-empathy backfire.
- Minimal cognitive demand: script execution, basic verbal fluency, rapid recovery from rejection.
- Below composite 35, basic verbal fluency and script memorization may become patchy — but only in extremes.
- Parity with competes_for_recognition (35): both are motivational/persistence competencies where the LSS floor barely bites.

Citations:
- Barrick & Mount 1991 — conscientiousness + emotional stability meta-analysis
- Vinchur, Schippmann, Switzer & Roth 1998 — sales cognitive-ability meta-analysis (cold outbound work)
- Judge & Ilies 2002 — personality traits + performance under repeated rejection
- Zhou/Kuncel/Sackett 2024; Kane 1996; Sweller 1988; Coward/Sackett 1990 — curve shape (see helper)$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor = EXCLUDED.floor, notes = EXCLUDED.notes,
    updated_at = now(), updated_by = EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_dials_cold_calls(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
/*
Competency: Dials Cold Calls (LSS Step 4 rewire — v2 signal + 2c curve via helper).
Base = 10.53 + 0.26*deadline_motivation + 0.21*assertiveness + 0.16*optimism
     + 0.11*independent_spirit + 0.11*self_promotion + 0.05*recognition_drive
     - 0.05*compassion - 0.05*analytical.
LSS penalty via hiregauge_lss_penalty_v2. Floor row: 'dials_cold_calls' (35).
*/
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN
    v_base := NULL;
  ELSE
    v_base := GREATEST(0, LEAST(100, ROUND(
      (10.526316) + (+0.263158)*dm + (+0.210526)*ass + (+0.157895)*op + (+0.105263)*is_val + (+0.105263)*sp + (+0.052632)*rd + (-0.052632)*com + (-0.052632)*an
    )::int));
  END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'dials_cold_calls';

  v_mult := public.hiregauge_lss_penalty_v2(v_composite, v_floor);

  IF v_base IS NULL THEN
    v_adjusted := NULL; v_delta := 0;
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

  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta,
    'composite', v_composite, 'floor', v_floor, 'lss_multiplier', v_mult, 'components', v_lss_result);
END; $function$;
