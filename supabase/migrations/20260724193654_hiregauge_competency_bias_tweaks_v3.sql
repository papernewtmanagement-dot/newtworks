-- HireGauge competency bias tweaks v3 — three fixes from post-v2 audit:
-- (1) balances_logic_and_emotion_when_hiring: name says "balances BOTH" but math treated
--     warmth/belief-in-others as negative. Flipped signs, adjusted intercept for baseline.
-- (2) pivots_to_customer_need: NULL anchor gated on dm but dm not in formula. Fixed to com.
-- (3) rapid_rapport_warm: same anchor bug. Fixed to com.

-- ============================================================================
-- 1. balances_logic_and_emotion_when_hiring
--    Semantic fix: com/bo -0.08 -> +0.08, intercept 23.5 -> 15.5.
--    Name promises "balances BOTH logic AND emotion" -> emotion should contribute
--    positively, not negatively. Assertiveness (0.33) and analytical (0.16) remain
--    dominant so the "logic" side is preserved; we're just no longer penalizing warmth.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.assessment_competency_balances_logic_and_emotion_when_hiring(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  bo numeric := public._assessment_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (15.500000)
    + (0.001378)*dm + (-0.001370)*rd + (0.329501)*ass
    + (0.165831)*is_val + (0.162491)*an + (0.080000)*com
    + (0.006637)*sp + (0.080000)*bo + (0.003683)*op
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'balances_logic_and_emotion_when_hiring';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._assessment_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$;

-- ============================================================================
-- 2. pivots_to_customer_need
--    Anchor bug: gates on dm but dm not in formula. Change to com (dominant trait).
--    Unused dm declaration removed.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.assessment_competency_pivots_to_customer_need(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  bo numeric := public._assessment_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF com IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (12.000000)
    + (0.250000)*com + (0.200000)*an + (0.150000)*ass
    + (0.100000)*op + (0.100000)*bo + (0.050000)*rd
    + (-0.050000)*is_val + (-0.050000)*sp
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'pivots_to_customer_need';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._assessment_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$;

-- ============================================================================
-- 3. rapid_rapport_warm
--    Same anchor bug as pivots. Change from dm to com. Unused dm declaration removed.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.assessment_competency_rapid_rapport_warm(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
  ass numeric := p_candidate.assertiveness;
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  bo numeric := public._assessment_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF com IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (20.000000)
    + (0.300000)*com + (0.200000)*op + (0.200000)*bo
    + (-0.100000)*an + (0.050000)*ass
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'rapid_rapport_warm';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._assessment_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$;
