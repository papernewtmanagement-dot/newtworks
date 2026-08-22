-- fn #24: receives_coaching (floor=40)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'receives_coaching', 40,
  $$Floor 40. Humility + retention competency. Base: intercept 40 + compassion (0.40) dominant + recognition_drive (0.15); assertiveness/independent_spirit/self_promotion carry NEGATIVE weights (over-assertive people resist coaching). Personality-driven with modest working-memory demand for retaining + integrating feedback across sessions. Parity with cadence_compliance, manages_time_effectively, has_entrepreneurial_spirit. Citations: Barrick & Mount 1991 (Agreeableness), Judge et al. 1999, Rynes et al. 2005 (coaching acceptance), Hunter & Hunter 1984, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_receives_coaching(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF com IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (40.000000) + (+0.150000)*rd + (-0.150000)*ass + (-0.150000)*is_val + (+0.400000)*com + (-0.100000)*sp + (+0.050000)*op
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'receives_coaching';
  v_mult := public.hiregauge_lss_penalty_v2(v_composite, v_floor);
  IF v_base IS NULL THEN v_adjusted := NULL; v_delta := 0;
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

-- fn #25: retention_watchfulness (floor=55)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'retention_watchfulness', 55,
  $$Floor 55. Hybrid cognitive-emotional competency. Base weights compassion (0.43) dominant + analytical (0.29). Belief_in_others AND optimism carry NEGATIVE weights (-0.07 each) — over-belief and over-optimism blind you to churn signals. Pattern-recognition + empathy combo for spotting customer distress signals early. Same hybrid tier as cross_sell_instinct, presents_solutions, pivots_to_customer_need, attention_to_detail. Below 55, ability to hold multiple customer-state signals in working memory + weigh them against baseline degrades. Citations: Frei & McDaniel 1998 (customer orientation), Salthouse 1996 (multi-attribute working memory), Vinchur/Schippmann/Switzer/Roth 1998, Barrick & Mount 1991, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_retention_watchfulness(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  dm numeric := p_candidate.deadline_motivation;
  ass numeric := p_candidate.assertiveness;
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  bo numeric := public._assessment_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF com IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (14.285714) + (+0.428571)*com + (+0.285714)*an + (+0.071429)*ass + (+0.071429)*dm + (-0.071429)*bo + (-0.071429)*op
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'retention_watchfulness';
  v_mult := public.hiregauge_lss_penalty_v2(v_composite, v_floor);
  IF v_base IS NULL THEN v_adjusted := NULL; v_delta := 0;
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

-- fn #26: routing_judgment (floor=55)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'routing_judgment', 55,
  $$Floor 55. Hybrid cognitive-decision competency. Base weights analytical (0.25) top + belief_in_others (0.20) + compassion (0.15). Independent_spirit AND self_promotion carry NEGATIVE weights (-0.10 each) — want people who defer to the routing system rather than override it. Real cognitive load: evaluate multiple routing options + choose the right destination for the customer/task. Below composite 55, decision quality on multi-attribute routing degrades. Same hybrid tier as retention_watchfulness, cross_sell_instinct, presents_solutions. Citations: Salthouse 1996 (multi-attribute decisions), Vinchur/Schippmann/Switzer/Roth 1998, Barrick & Mount 1991, Judge et al. 1999, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_routing_judgment(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
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
  bo numeric := public._assessment_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF an IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (25.000000) + (+0.250000)*an + (+0.200000)*bo + (+0.150000)*com + (+0.050000)*dm + (+0.050000)*op + (+0.050000)*ass + (-0.050000)*rd + (-0.100000)*is_val + (-0.100000)*sp
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'routing_judgment';
  v_mult := public.hiregauge_lss_penalty_v2(v_composite, v_floor);
  IF v_base IS NULL THEN v_adjusted := NULL; v_delta := 0;
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

-- fn #27: works_without_close_supervision (floor=40)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'works_without_close_supervision', 40,
  $$Floor 40. Self-management competency. Base = 0.34*assertiveness + 0.33*deadline_motivation + 0.33*independent_spirit — 3-trait equal split. Personality-driven with modest working-memory demand for self-directed planning + execution. Parity with has_entrepreneurial_spirit, cadence_compliance, manages_time_effectively, receives_coaching. Citations: Barrick & Mount 1991 (conscientiousness), Judge et al. 1999, Hunter & Hunter 1984, Salthouse 1996, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_works_without_close_supervision(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  ass numeric := p_candidate.assertiveness;
  dm numeric := p_candidate.deadline_motivation;
  is_val numeric := p_candidate.independent_spirit;
BEGIN
  IF ass IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (0.000000) + (+0.340000)*ass + (+0.330000)*dm + (+0.330000)*is_val
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'works_without_close_supervision';
  v_mult := public.hiregauge_lss_penalty_v2(v_composite, v_floor);
  IF v_base IS NULL THEN v_adjusted := NULL; v_delta := 0;
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
