-- Batch 3 (character/nurture): 5 per-competency v2 functions.
-- Two use raw-trait bases (positively_influences_team=optimism dampened,
-- competes_for_recognition=recognition_drive raw). Three use multi-trait regressions.

CREATE OR REPLACE FUNCTION public.cts_competency_receives_coaching_v2(p_candidate hiring_candidates)
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
  IF com IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (33.550072)
    + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass
    + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com
    + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'receives_coaching';
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

CREATE OR REPLACE FUNCTION public.cts_competency_positively_influences_team_v2(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
  op numeric := public._cts_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF op IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(op)::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'positively_influences_team';
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

CREATE OR REPLACE FUNCTION public.cts_competency_competes_for_recognition_v2(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
BEGIN
  IF p_candidate.recognition_drive IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, p_candidate.recognition_drive)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'competes_for_recognition';
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

CREATE OR REPLACE FUNCTION public.cts_competency_works_without_close_supervision_v2(p_candidate hiring_candidates)
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
    (0.014435)
    + (0.334137)*dm + (0.000589)*rd + (0.329735)*ass
    + (0.334420)*is_val + (0.001923)*an + (0.000663)*com
    + (-0.001501)*sp + (-0.002410)*bo + (-0.003302)*op
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'works_without_close_supervision';
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

CREATE OR REPLACE FUNCTION public.cts_competency_has_entrepreneurial_spirit_v2(p_candidate hiring_candidates)
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
    (0.052334)
    + (0.249428)*dm + (0.001218)*rd + (0.254556)*ass
    + (0.495006)*is_val + (-0.004124)*an + (-0.003403)*com
    + (0.006260)*sp + (-0.004916)*bo + (-0.003735)*op
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'has_entrepreneurial_spirit';
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
