-- Batch 4 (throughput): 5 per-competency v2 functions. All multi-trait regressions.

CREATE OR REPLACE FUNCTION public.cts_competency_cadence_compliance_v2(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  sp numeric := p_candidate.self_promotion;
  bo numeric := public._cts_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._cts_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (22.000000)
    + (0.250000)*dm + (0.150000)*an + (0.150000)*rd
    + (0.100000)*bo + (0.050000)*op + (-0.100000)*is_val
    + (-0.050000)*sp
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'cadence_compliance';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._cts_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$
;

CREATE OR REPLACE FUNCTION public.cts_competency_proactive_touch_discipline_v2(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  an numeric := p_candidate.analytical;
  com numeric := public._cts_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  op numeric := public._cts_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (20.000000)
    + (0.250000)*dm + (0.150000)*an + (0.150000)*com
    + (0.100000)*rd + (0.050000)*op
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'proactive_touch_discipline';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._cts_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$
;

CREATE OR REPLACE FUNCTION public.cts_competency_is_fast_start_oriented_v2(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  com numeric := public._cts_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := p_candidate.self_promotion;
  bo numeric := public._cts_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._cts_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (-0.195183)
    + (0.402392)*dm + (0.201362)*rd + (0.202542)*ass
    + (0.198936)*is_val + (0.000119)*an + (-0.003170)*com
    + (-0.001383)*sp + (-0.001712)*bo + (0.000563)*op
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'is_fast_start_oriented';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._cts_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$
;

CREATE OR REPLACE FUNCTION public.cts_competency_makes_decisions_quickly_v2(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  com numeric := public._cts_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := p_candidate.self_promotion;
  bo numeric := public._cts_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._cts_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (28.788259)
    + (0.144387)*dm + (0.001618)*rd + (0.140225)*ass
    + (0.137139)*is_val + (-0.143650)*an + (-0.146024)*com
    + (0.147148)*sp + (-0.001939)*bo + (0.138712)*op
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'makes_decisions_quickly';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._cts_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$
;

CREATE OR REPLACE FUNCTION public.cts_competency_manages_time_effectively_v2(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  com numeric := public._cts_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := p_candidate.self_promotion;
  bo numeric := public._cts_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._cts_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (33.197370)
    + (0.167938)*dm + (0.170463)*rd + (0.173435)*ass
    + (0.164096)*is_val + (-0.167532)*an + (-0.167799)*com
    + (0.001946)*sp + (-0.006913)*bo + (-0.005379)*op
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'manages_time_effectively';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._cts_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$
;
