-- fn #12: is_fast_start_oriented (floor=35)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'is_fast_start_oriented', 35,
  $$Floor 35. Motivational competency. Base = 0.40*deadline_motivation + 0.20 each of recognition_drive, assertiveness, independent_spirit. Zero cognitive weights in base — pure temperament/drive. Below composite 35, general cognitive strain may make new-task startup patchy, but only in extremes. Parity with competes_for_recognition, dials_cold_calls, handles_rejection. Citations: Barrick & Mount 1991, Judge et al. 1999, Hunter & Hunter 1984, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_is_fast_start_oriented(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
BEGIN
  IF dm IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (0.000000) + (+0.400000)*dm + (+0.200000)*rd + (+0.200000)*ass + (+0.200000)*is_val
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'is_fast_start_oriented';
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

-- fn #13: listens_discovers_needs (floor=50)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'listens_discovers_needs', 50,
  $$Floor 50. Hybrid cognitive-emotional competency. Base weights compassion (0.25) = recognition_drive (0.25) at top; analytical NEGATIVE (-0.10) — over-thinking blocks active listening. Requires sustained attention, conversational context maintenance, stated-to-underlying-need translation. Below composite 50, multi-turn dialogue tracking may become patchy. Between motivational (35) and reasoning-heavy (60). Citations: Frei & McDaniel 1998 (customer service orientation), Judge & Kammeyer-Mueller 2012 (person-perception), Salthouse 1996 (working-memory maintenance), Barrick & Mount 1991 (Agreeableness in service roles), Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_listens_discovers_needs(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
  bo numeric := public._assessment_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
BEGIN
  IF com IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (20.000000) + (+0.250000)*rd + (+0.150000)*ass + (-0.100000)*an + (+0.250000)*com + (+0.000000)*sp + (-0.100000)*op + (+0.150000)*bo
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'listens_discovers_needs';
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

-- fn #14: maintains_high_activity (floor=35)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'maintains_high_activity', 35,
  $$Floor 35. Pure activity/throughput competency. Base weights deadline_motivation (0.50) dominant + independent_spirit (0.12) + recognition_drive (0.13); analytical NEGATIVE (-0.05). Sustained activity output driven by drive + persistence, not cognition. Below composite 35, basic task execution may become patchy but only in extremes. Parity with dials_cold_calls, competes_for_recognition, handles_rejection. Citations: Barrick & Mount 1991 (conscientiousness), Judge et al. 1999, Hunter & Hunter 1984, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990.$$,
  'claude_conversation')
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_maintains_high_activity(p_candidate hiring_candidates)
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
    (15.000000) + (+0.130000)*rd + (+0.100000)*ass + (-0.050000)*an + (+0.500000)*dm + (+0.120000)*is_val + (-0.050000)*com + (-0.050000)*op
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'maintains_high_activity';
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
