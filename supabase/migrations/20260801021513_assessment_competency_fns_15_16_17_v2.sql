-- fn #15: makes_decisions_quickly (floor=45)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'makes_decisions_quickly', 45,
  $$Floor 45. Executive-function + decisiveness competency. Base weights deadline_motivation (0.19), self_promotion (0.18), assertiveness/independent_spirit/optimism (0.17 each); analytical NEGATIVE (-0.06) — over-analysis blocks quick decisions. Requires basic cognitive processing to arrive at a decision + temperament to commit. Parity with composure_under_load (hybrid personality + executive function). Citations: Kahneman 2011 (System 1 vs System 2), Barrick & Mount 1991, Judge & Ilies 2002, Baumeister et al. 1998, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_makes_decisions_quickly(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  dm numeric := p_candidate.deadline_motivation;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (12.000000) + (+0.190000)*dm + (+0.170000)*ass + (+0.170000)*is_val + (-0.060000)*an + (-0.060000)*com + (+0.180000)*sp + (+0.170000)*op
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'makes_decisions_quickly';
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

-- fn #16: manages_time_effectively (floor=40)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'manages_time_effectively', 40,
  $$Floor 40. Planning + prioritization competency. Base weights deadline_motivation (0.50) dominant + recognition_drive (0.13) + independent_spirit (0.11) + analytical POSITIVE but small (0.06). Conscientiousness-driven with modest planning cognitive load. Parity with cadence_compliance (40) — both are personality-driven with schedule/task working-memory demand. Citations: Barrick & Mount 1991 (conscientiousness meta-analysis, r≈.22 with performance), Judge et al. 1999, Salthouse 1996 (working-memory for planning), Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_manages_time_effectively(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  an numeric := p_candidate.analytical;
  dm numeric := p_candidate.deadline_motivation;
  is_val numeric := p_candidate.independent_spirit;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (10.000000) + (+0.130000)*rd + (+0.100000)*ass + (+0.060000)*an + (+0.500000)*dm + (+0.110000)*is_val + (-0.050000)*com + (-0.050000)*op
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'manages_time_effectively';
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

-- fn #17: pivots_to_customer_need (floor=55)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'pivots_to_customer_need', 55,
  $$Floor 55. Hybrid cognitive-emotional competency. Base weights compassion (0.26) + analytical (0.21) top. Real-time attention shift + reprioritization based on customer signal — requires reading nonverbal cues + rapid re-planning. Same hybrid tier as cross_sell_instinct (55) and attention_to_detail (55). Below 55, ability to redirect mid-conversation while maintaining rapport degrades. Citations: Vinchur/Schippmann/Switzer/Roth 1998, Frei & McDaniel 1998 (customer service orientation), Salthouse 1996 (task-switching under attentional load), Barrick & Mount 1991, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_pivots_to_customer_need(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
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
    (10.526316) + (+0.263158)*com + (+0.210526)*an + (+0.157895)*ass + (+0.105263)*op + (+0.105263)*bo + (+0.052632)*rd + (-0.052632)*is_val + (-0.052632)*sp
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'pivots_to_customer_need';
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
