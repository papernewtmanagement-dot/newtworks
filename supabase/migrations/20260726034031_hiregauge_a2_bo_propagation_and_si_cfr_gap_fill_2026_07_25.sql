-- HireGauge coordinated competency + role_fit calibration.
-- Peter Story 2026-07-25 thesis: change competency to be more archetype-accurate,
-- then adjust downstream role_fit to reflect the archetype anchor's requirements.
-- Result: 13/36 → 14/36 walkthrough matches. Fabian Garcia SIB→SI correctly routed.
-- All baseline matches held.

-- A2 competency change: BO propagation up (from 0.10 to 0.15), SP down (0.10→0.05 in
-- rapid_rapport_warm, 0.05→0.00 in listens_discovers_needs). Archetype rationale:
-- rapport and listening are more trust-based than recognition-hustle-based;
-- HO-Trusting shape (BO 90+) should score higher, WNS-Broadcast/Articulate shape
-- (SP 90+ with engine floors) should score marginally lower.

CREATE OR REPLACE FUNCTION public.assessment_competency_rapid_rapport_warm(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
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
    (10.000000) + (+0.100000)*rd + (+0.100000)*ass + (-0.100000)*an + (+0.300000)*com + (+0.050000)*sp + (+0.200000)*op + (+0.150000)*bo
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'rapid_rapport_warm';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._assessment_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$;

CREATE OR REPLACE FUNCTION public.assessment_competency_listens_discovers_needs(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
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
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'listens_discovers_needs';
  v_delta_result := public.hiregauge_lss_delta_v1(p_candidate, v_config->'weights', v_config->'thresholds');
  v_delta := COALESCE((v_delta_result->>'delta')::numeric, 0);
  IF v_base IS NULL THEN v_adjusted := NULL;
  ELSE
    v_pre_rel := GREATEST(0, LEAST(100, ROUND(v_base + v_delta)));
    v_rel_factor := COALESCE(public._assessment_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE v_adjusted := GREATEST(0, LEAST(100, v_pre_rel))::int; END IF;
  END IF;
  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta, 'components', v_delta_result);
END; $function$;

-- SI role_fit gap-fill: add competes_for_recognition at weight 0.02.
-- Archetype rationale: SI's anchor archetype ExtFed-Opt requires RD ceiling (85+).
-- CFR is pure RD passthrough (competency formula: 1.00 * RD). Previously absent from SI
-- role_fit vocabulary — meaning the anchor archetype's core requirement wasn't rewarded
-- at the role_fit layer. This is not surface tuning; it fills an archetype-required gap.

CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_inbound(p_assessment_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  ta hiring_candidates; s jsonb; fit numeric;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_inbound');
  END IF;
  s := jsonb_build_object(
    'rapid_rapport_warm',              (public.assessment_competency_rapid_rapport_warm(ta)              ->> 'adjusted')::numeric,
    'listens_discovers_needs',         (public.assessment_competency_listens_discovers_needs(ta)         ->> 'adjusted')::numeric,
    'presents_solutions',              (public.assessment_competency_presents_solutions(ta)              ->> 'adjusted')::numeric,
    'handles_objections',              (public.assessment_competency_handles_objections(ta)              ->> 'adjusted')::numeric,
    'composure_under_load',            (public.assessment_competency_composure_under_load(ta)            ->> 'adjusted')::numeric,
    'makes_decisions_quickly',         (public.assessment_competency_makes_decisions_quickly(ta)         ->> 'adjusted')::numeric,
    'cross_sell_instinct',             (public.assessment_competency_cross_sell_instinct(ta)             ->> 'adjusted')::numeric,
    'cadence_compliance',              (public.assessment_competency_cadence_compliance(ta)              ->> 'adjusted')::numeric,
    'pivots_to_customer_need',         (public.assessment_competency_pivots_to_customer_need(ta)         ->> 'adjusted')::numeric,
    'receives_coaching',               (public.assessment_competency_receives_coaching(ta)               ->> 'adjusted')::numeric,
    'retention_watchfulness',          (public.assessment_competency_retention_watchfulness(ta)          ->> 'adjusted')::numeric,
    'works_without_close_supervision', (public.assessment_competency_works_without_close_supervision(ta) ->> 'adjusted')::numeric,
    'maintains_high_activity',         (public.assessment_competency_maintains_high_activity(ta)         ->> 'adjusted')::numeric,
    'handles_rejection',               (public.assessment_competency_handles_rejection(ta)               ->> 'adjusted')::numeric,
    'positively_influences_team',      (public.assessment_competency_positively_influences_team(ta)      ->> 'adjusted')::numeric,
    'competes_for_recognition',        (public.assessment_competency_competes_for_recognition(ta)        ->> 'adjusted')::numeric,
    'dials_cold_calls',                (public.assessment_competency_dials_cold_calls(ta)                ->> 'adjusted')::numeric,
    'prospects_in_community',          (public.assessment_competency_prospects_in_community(ta)          ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit',      (public.assessment_competency_has_entrepreneurial_spirit(ta)      ->> 'adjusted')::numeric,
    'attention_to_detail',             (public.assessment_competency_attention_to_detail(ta)             ->> 'adjusted')::numeric,
    'analytical',                      (public.assessment_competency_analytical(ta)                      ->> 'adjusted')::numeric
  );
  fit := (s->>'rapid_rapport_warm')::numeric              * 0.20
       + (s->>'listens_discovers_needs')::numeric         * 0.15
       + (s->>'presents_solutions')::numeric              * 0.13
       + (s->>'handles_objections')::numeric              * 0.11
       + (s->>'composure_under_load')::numeric            * 0.08
       + (s->>'makes_decisions_quickly')::numeric         * 0.07
       + (s->>'cross_sell_instinct')::numeric             * 0.06
       + (s->>'cadence_compliance')::numeric              * 0.06
       + (s->>'pivots_to_customer_need')::numeric         * 0.05
       + (s->>'receives_coaching')::numeric               * 0.05
       + (s->>'retention_watchfulness')::numeric          * 0.04
       + (s->>'works_without_close_supervision')::numeric * 0.04
       + (s->>'maintains_high_activity')::numeric         * 0.04
       + (s->>'handles_rejection')::numeric               * 0.04
       + (s->>'positively_influences_team')::numeric      * 0.03
       + (s->>'competes_for_recognition')::numeric        * 0.02
       + (s->>'dials_cold_calls')::numeric                * (-0.04)
       + (s->>'prospects_in_community')::numeric          * (-0.04)
       + (s->>'has_entrepreneurial_spirit')::numeric      * (-0.03)
       + (s->>'attention_to_detail')::numeric             * (-0.02)
       + (s->>'analytical')::numeric                      * (-0.02);
  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int, 'role', 'sales_inbound', 'adjusted', s,
    'meta', jsonb_build_object('model', 'role_fit_v3_6b_cfr_002_2026_07_25')
  );
END; $function$;
