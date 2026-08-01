-- Batch update: 4 shipped competency fns now call hiregauge_lss_penalty_v2 helper
-- instead of hardcoded inline exponential formula. Slope constant + curve shape
-- now live in exactly one place (the helper).
--
-- Behavior is byte-for-byte identical (helper wraps same formula). Migration
-- exists to enforce the single-source-of-truth pattern before shipping the
-- remaining 23 competency fns + 7 role_fit fns.

CREATE OR REPLACE FUNCTION public.assessment_competency_analytical(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
/*
Competency: Analytical (LSS Step 4 rewire — v2 signal + 2c curve via helper).
Base score = 15 + 0.70*analytical + 0.15*independent_spirit - 0.10*self_promotion - 0.05*belief_in_others.
LSS penalty via hiregauge_lss_penalty_v2(composite, floor). Floor row: competency_name='analytical'.
Reliability adjustment around 50 midpoint unchanged.
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
  IF an IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (15.000000) + (0.700000)*an + (0.150000)*is_val + (-0.100000)*sp + (-0.050000)*bo
  )::int)); END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
  WHERE agency_id = p_candidate.agency_id AND competency_name = 'analytical';

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
END;
$function$;

CREATE OR REPLACE FUNCTION public.assessment_competency_attention_to_detail(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
/*
Competency: Attention to Detail (LSS Step 4 rewire — v2 signal + 2c curve via helper).
Base = 14.29 + 0.43*analytical + 0.21*deadline_motivation + 0.14*recognition_drive
     + 0.07*independent_spirit - 0.07*optimism - 0.07*self_promotion.
LSS penalty via hiregauge_lss_penalty_v2(composite, floor). Floor row: competency_name='attention_to_detail'.
*/
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF an IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (14.285714) + (+0.428571)*an + (+0.214286)*dm + (+0.142857)*rd + (+0.071429)*is_val + (-0.071429)*op + (-0.071429)*sp
  )::int)); END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
  WHERE agency_id = p_candidate.agency_id AND competency_name = 'attention_to_detail';

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
END;
$function$;

CREATE OR REPLACE FUNCTION public.assessment_competency_balances_logic_and_emotion_when_hiring(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
/*
Competency: Balances Logic and Emotion when Hiring (LSS Step 4 rewire — v2 signal + 2c curve via helper).
Base = 30 - 0.05*recognition_drive + 0.35*assertiveness + 0.15*analytical + 0.20*independent_spirit
     - 0.15*compassion - 0.10*self_promotion.
LSS penalty via hiregauge_lss_penalty_v2(composite, floor). Floor row: competency_name='balances_logic_and_emotion_when_hiring'.
*/
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  an numeric := p_candidate.analytical;
  is_val numeric := p_candidate.independent_spirit;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
BEGIN
  IF ass IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (30.000000) + (-0.050000)*rd + (+0.350000)*ass + (+0.150000)*an + (+0.200000)*is_val + (-0.150000)*com + (-0.100000)*sp
  )::int)); END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
  WHERE agency_id = p_candidate.agency_id AND competency_name = 'balances_logic_and_emotion_when_hiring';

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
END;
$function$;

CREATE OR REPLACE FUNCTION public.assessment_competency_cadence_compliance(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
/*
Competency: Cadence Compliance (LSS Step 4 rewire — v2 signal + 2c curve via helper).
Base = 15 + 0.15*recognition_drive + 0.10*assertiveness + 0.10*analytical + 0.45*deadline_motivation
     - 0.10*independent_spirit - 0.05*self_promotion + 0.05*optimism.
LSS penalty via hiregauge_lss_penalty_v2(composite, floor). Floor row: competency_name='cadence_compliance'.
*/
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  an numeric := p_candidate.analytical;
  dm numeric := p_candidate.deadline_motivation;
  is_val numeric := p_candidate.independent_spirit;
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (15.000000) + (+0.150000)*rd + (+0.100000)*ass + (+0.100000)*an + (+0.450000)*dm + (-0.100000)*is_val + (-0.050000)*sp + (+0.050000)*op
  )::int)); END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
  WHERE agency_id = p_candidate.agency_id AND competency_name = 'cadence_compliance';

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
END;
$function$;
