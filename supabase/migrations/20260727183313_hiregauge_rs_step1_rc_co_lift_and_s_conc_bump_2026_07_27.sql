-- RS coordinated calibration step 1
-- Competency change: receives_coaching compassion coefficient 0.35 -> 0.40, optimism 0.10 -> 0.05
--   Archetype rationale: compassion drives coaching-openness in the RS archetype-union
--   (Silent Task-Driver, Overthinker/Non-Executor, Analyst-shapes all lean coachable via warmth,
--   not via cheerful-optimism which correlates with coaching-rejection in Cold-Hollow Hollow Optimist
--   + High-Distortion Producer archetypes).
-- Role_fit change: retention_support signal_concern weight 0.10 -> 0.13
--   Gap fill: RS role_fit under-weights compassion vs the anchor+over-fire signal cluster (avg 34 vs Thomas 14).

CREATE OR REPLACE FUNCTION public.assessment_competency_receives_coaching(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_base int; v_config jsonb; v_delta_result jsonb; v_delta numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int;
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
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'receives_coaching';
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

CREATE OR REPLACE FUNCTION public.assessment_role_fit_retention_support(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  s jsonb;
  fit numeric;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_support');
  END IF;

  s := jsonb_build_object(
    'attention_to_detail',             (public.assessment_competency_attention_to_detail(ta)             ->> 'adjusted')::numeric,
    'manages_time_effectively',        (public.assessment_competency_manages_time_effectively(ta)        ->> 'adjusted')::numeric,
    'maintains_high_activity',         (public.assessment_competency_maintains_high_activity(ta)         ->> 'adjusted')::numeric,
    'queue_throughput_discipline',     (public.assessment_competency_queue_throughput_discipline(ta)     ->> 'adjusted')::numeric,
    'works_without_close_supervision', (public.assessment_competency_works_without_close_supervision(ta) ->> 'adjusted')::numeric,
    'cadence_compliance',              (public.assessment_competency_cadence_compliance(ta)              ->> 'adjusted')::numeric,
    'receives_coaching',               (public.assessment_competency_receives_coaching(ta)               ->> 'adjusted')::numeric,
    'analytical',                      (public.assessment_competency_analytical(ta)                      ->> 'adjusted')::numeric,
    'makes_decisions_quickly',         (public.assessment_competency_makes_decisions_quickly(ta)         ->> 'adjusted')::numeric,
    'listens_discovers_needs',         (public.assessment_competency_listens_discovers_needs(ta)         ->> 'adjusted')::numeric,
    'retention_watchfulness',          (public.assessment_competency_retention_watchfulness(ta)          ->> 'adjusted')::numeric,
    'positively_influences_team',      (public.assessment_competency_positively_influences_team(ta)      ->> 'adjusted')::numeric,
    'proactive_touch_discipline',      (public.assessment_competency_proactive_touch_discipline(ta)      ->> 'adjusted')::numeric,
    'routing_judgment',                (public.assessment_competency_routing_judgment(ta)                ->> 'adjusted')::numeric,
    'competes_for_recognition',        (public.assessment_competency_competes_for_recognition(ta)        ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit',      (public.assessment_competency_has_entrepreneurial_spirit(ta)      ->> 'adjusted')::numeric,
    'dials_cold_calls',                (public.assessment_competency_dials_cold_calls(ta)                ->> 'adjusted')::numeric,
    'prospects_in_community',          (public.assessment_competency_prospects_in_community(ta)          ->> 'adjusted')::numeric,
    'is_fast_start_oriented',          (public.assessment_competency_is_fast_start_oriented(ta)          ->> 'adjusted')::numeric,
    'signal_concern',                  (public.assessment_signal_concern(ta)                             ->> 'adjusted')::numeric,
    'signal_hwe',                      (public.assessment_signal_hwe(ta)                                 ->> 'adjusted')::numeric,
    'signal_drive_engine',             (public.assessment_signal_drive_engine(ta)                        ->> 'adjusted')::numeric,
    'signal_honesty',                  (public.assessment_signal_honesty(ta)                             ->> 'adjusted')::numeric,
    'signal_overthinker_penalty',      (public.assessment_signal_overthinker_penalty(ta)                 ->> 'adjusted')::numeric
  );

  fit := (s->>'attention_to_detail')::numeric             * 0.16
       + (s->>'manages_time_effectively')::numeric        * 0.16
       + (s->>'queue_throughput_discipline')::numeric     * 0.12
       + (s->>'maintains_high_activity')::numeric         * 0.11
       + (s->>'listens_discovers_needs')::numeric         * 0.10
       + (s->>'works_without_close_supervision')::numeric * 0.09
       + (s->>'receives_coaching')::numeric               * 0.10
       + (s->>'cadence_compliance')::numeric              * 0.08
       + (s->>'analytical')::numeric                      * 0.06
       + (s->>'signal_concern')::numeric                  * 0.13
       + (s->>'retention_watchfulness')::numeric          * 0.06
       + (s->>'makes_decisions_quickly')::numeric         * 0.06
       + (s->>'positively_influences_team')::numeric      * 0.04
       + (s->>'signal_hwe')::numeric                      * 0.03
       + (s->>'signal_drive_engine')::numeric             * 0.03
       + (s->>'signal_honesty')::numeric                  * 0.02
       + (s->>'proactive_touch_discipline')::numeric      * 0.03
       + (s->>'routing_judgment')::numeric                * 0.03
       + (s->>'signal_overthinker_penalty')::numeric      * (-0.03)
       + (s->>'has_entrepreneurial_spirit')::numeric      * (-0.18)
       + (s->>'competes_for_recognition')::numeric        * (-0.08)
       + (s->>'dials_cold_calls')::numeric                * (-0.04)
       + (s->>'prospects_in_community')::numeric          * (-0.04)
       + (s->>'is_fast_start_oriented')::numeric          * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_support',
    'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v4_0_rc_co_lift_and_s_conc_bump_2026_07_27',
      'changes_from_v3_9', 'receives_coaching competency: compassion coef 0.35->0.40, optimism coef 0.10->0.05 (archetype anchor to RS-union compassion signature). RS role_fit signal_concern weight 0.10->0.13.'
    )
  );
END;
$function$;
