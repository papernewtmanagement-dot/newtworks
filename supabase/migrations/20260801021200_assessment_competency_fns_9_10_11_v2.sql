-- Step 4 rewire fns #9-11: handles_objections, handles_rejection, has_entrepreneurial_spirit
-- Batched migration; each ships an atomic pair (floor row + fn rewrite).

-- fn #9: handles_objections (floor=45)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'handles_objections', 45,
  $notes$Floor 45. Real-time verbal reframe under sales pressure. Base weights recognition_drive (0.24) + self_promotion (0.22) + assertiveness (0.15); modest analytical (0.10). Requires rapid mental reframe + verbal fluency + on-the-fly counter-argument construction. Working-memory load real but moderate. Between motivational (35) and hybrid-cognitive (55). Citations: Vinchur/Schippmann/Switzer/Roth 1998 (sales meta-analysis), Barrick & Mount 1991 (extraversion + emotional stability), Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990 (curve shape via helper).$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_handles_objections(p_candidate hiring_candidates)
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
  IF rd IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (10.000000) + (+0.240000)*rd + (+0.150000)*ass + (+0.100000)*an + (+0.100000)*dm + (-0.100000)*com + (+0.220000)*sp + (+0.090000)*op
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'handles_objections';
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

-- fn #10: handles_rejection (floor=35)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'handles_rejection', 35,
  $notes$Floor 35. Pure emotional resilience competency. Base weights optimism (0.33) + independent_spirit (0.21) heaviest; analytical NEGATIVE weight (-0.06). Bouncing back from rejection is temperament + emotional regulation, not cognition. Same tier as competes_for_recognition and dials_cold_calls. Citations: Barrick & Mount 1991 (Neuroticism/emotional stability), Judge & Ilies 2002 (personality × repeated stress), Scheier & Carver 1985 (dispositional optimism), Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990 (curve shape via helper).$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_handles_rejection(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
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
  IF op IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (6.000000) + (+0.060000)*rd + (+0.110000)*ass + (-0.060000)*an + (+0.170000)*dm + (+0.210000)*is_val + (+0.060000)*sp + (+0.330000)*op
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'handles_rejection';
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

-- fn #11: has_entrepreneurial_spirit (floor=40)
INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'has_entrepreneurial_spirit', 40,
  $notes$Floor 40. Personality-driven with modest self-management working-memory load. Base weights: independent_spirit (0.51) dominant, deadline_motivation (0.25), assertiveness (0.24). Entrepreneurial drive is temperament-based; below composite 40, working-memory load of self-directed planning + execution without close supervision may become patchy. Parity with cadence_compliance (40). Citations: Zhao & Seibert 2006 (entrepreneurship personality meta-analysis), Rauch & Frese 2007 (Big Five × entrepreneurial success), Barrick & Mount 1991, Hunter & Hunter 1984, Zhou/Kuncel/Sackett 2024, Kane 1996, Sweller 1988, Coward/Sackett 1990 (curve shape via helper).$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor=EXCLUDED.floor, notes=EXCLUDED.notes, updated_at=now(), updated_by=EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_has_entrepreneurial_spirit(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  ass numeric := p_candidate.assertiveness;
  dm numeric := p_candidate.deadline_motivation;
  is_val numeric := p_candidate.independent_spirit;
BEGIN
  IF is_val IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (0.000000) + (+0.240000)*ass + (+0.250000)*dm + (+0.510000)*is_val
  )::int)); END IF;
  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;
  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'has_entrepreneurial_spirit';
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
