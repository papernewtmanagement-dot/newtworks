-- fn #18: positively_influences_team (floor=35)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'positively_influences_team', 35,
  $$Floor 35. Pure social-emotional competency. Base = 0.70*optimism + 0.15*assertiveness + 0.15*compassion. Optimism DOMINATES massively; zero cognitive weights in base. Being a positive team influence is temperament — optimism carries it. Parity with competes_for_recognition, dials_cold_calls, handles_rejection. Citations: Scheier & Carver 1985 (dispositional optimism), Judge et al. 2002 (transformational leadership × optimism), Barrick & Mount 1991 (extraversion), Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_positively_influences_team(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  ass numeric := p_candidate.assertiveness;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF op IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (0.000000) + (+0.150000)*ass + (+0.150000)*com + (+0.700000)*op
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'positively_influences_team';
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

-- fn #19: presents_solutions (floor=55)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'presents_solutions', 55,
  $$Floor 55. Hybrid cognitive-communication competency. Base weights analytical (0.25) tied with assertiveness (0.25); recognition_drive (0.20), self_promotion (0.15), compassion (0.10). Real cognitive load: structuring a solution + articulating it clearly requires reasoning + expressive verbal fluency. Same tier as cross_sell_instinct, attention_to_detail, pivots_to_customer_need. Below composite 55, ability to organize solution components while presenting degrades. Citations: Vinchur/Schippmann/Switzer/Roth 1998 (sales meta-analysis, communication × g), Salthouse 1996 (working-memory for complex output), Barrick & Mount 1991, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_presents_solutions(p_candidate hiring_candidates)
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
BEGIN
  IF rd IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (5.000000) + (+0.200000)*rd + (+0.250000)*ass + (+0.150000)*sp + (+0.250000)*an + (+0.100000)*com + (-0.050000)*is_val
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'presents_solutions';
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

-- fn #20: proactive_touch_discipline (floor=40)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'proactive_touch_discipline', 40,
  $$Floor 40. Customer follow-up rhythm competency. Base weights deadline_motivation (0.40) dominant + compassion (0.15), assertiveness (0.15), analytical POSITIVE modest (0.10). Requires holding customer-touch list in working memory + executing on cadence. Conscientiousness-driven with modest working-memory demand. Parity with manages_time_effectively (40), cadence_compliance (40). Citations: Barrick & Mount 1991 (conscientiousness), Judge et al. 1999, Salthouse 1996 (working-memory maintenance), Frei & McDaniel 1998 (customer service orientation), Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_proactive_touch_discipline(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  an numeric := p_candidate.analytical;
  dm numeric := p_candidate.deadline_motivation;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (5.000000) + (+0.100000)*rd + (+0.150000)*ass + (+0.100000)*an + (+0.400000)*dm + (+0.150000)*com + (-0.050000)*sp + (+0.050000)*op
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'proactive_touch_discipline';
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
