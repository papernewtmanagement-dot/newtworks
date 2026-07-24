-- 20260724021225_hiregauge_cts_competency_handles_objections_v2.sql
-- Create per-competency v2 function for handles_objections.
-- Reads lss_config from hiregauge_competencies, delegates LSS math to the
-- shared pure primitive hiregauge_lss_delta_v1 (created in 20260724022121).
-- Returns {base, adjusted, delta, components}.
-- NOTE: This file records the SIGNATURE and final body. The initial 150-line
-- inline-primitive version was superseded by the refactored form later in
-- the same session (20260724022315). The refactored body reproduced here
-- makes 20260724022315 a no-op replacement for this specific competency,
-- preserving byte-identical final state.

CREATE OR REPLACE FUNCTION public.cts_competency_handles_objections_v2(p_candidate hiring_candidates)
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
    (21.029494)
    + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val
    + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'handles_objections';
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
