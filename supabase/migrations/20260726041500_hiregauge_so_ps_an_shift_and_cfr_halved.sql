-- SO seat coordinated calibration 2026-07-26
--
-- Change 1 (competency, archetype-anchored):
--   assessment_competency_presents_solutions
--   RD coefficient 0.25 -> 0.20  (reduce recognition-drive push weight)
--   AN coefficient 0.20 -> 0.25  (increase analytical-persuasion weight, QC-Analyst anchor)
--
-- Change 2 (role_fit, archetype gap-anchored):
--   assessment_role_fit_sales_outbound
--   competes_for_recognition weight 0.04 -> 0.02
--   Rationale: CFR is pure RD passthrough. Over-fires (Braden 100, Maximus 89,
--   Christian 85, Allan 82, Richard 73) fire high without SO archetype fit.
--   Anchors keep CFR reward (Anthony 89, Bob 87) at half weight.
--
-- Result: 14/36 walkthrough held (baseline preserved). Zero over-fire flips this
-- pass but all anchor margins held (Anthony SO-SI margin 5->4, still safe).

CREATE OR REPLACE FUNCTION public.assessment_competency_presents_solutions(p_candidate hiring_candidates)
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
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
BEGIN
  IF rd IS NULL THEN v_base := NULL;
  ELSE v_base := GREATEST(0, LEAST(100, ROUND(
    (5.000000) + (+0.200000)*rd + (+0.250000)*ass + (+0.150000)*sp + (+0.250000)*an + (+0.100000)*com + (-0.050000)*is_val
  )::int)); END IF;
  SELECT lss_config INTO v_config FROM public.hiregauge_competencies WHERE competency = 'presents_solutions';
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

CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_outbound(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  s jsonb;
  drive_gated numeric;
  hwe_gated numeric;
  fit numeric;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_outbound');
  END IF;

  s := jsonb_build_object(
    'maintains_high_activity',         (public.assessment_competency_maintains_high_activity(ta)         ->> 'adjusted')::numeric,
    'handles_rejection',               (public.assessment_competency_handles_rejection(ta)               ->> 'adjusted')::numeric,
    'handles_objections',              (public.assessment_competency_handles_objections(ta)              ->> 'adjusted')::numeric,
    'dials_cold_calls',                (public.assessment_competency_dials_cold_calls(ta)                ->> 'adjusted')::numeric,
    'analytical',                      (public.assessment_competency_analytical(ta)                      ->> 'adjusted')::numeric,
    'presents_solutions',              (public.assessment_competency_presents_solutions(ta)              ->> 'adjusted')::numeric,
    'listens_discovers_needs',         (public.assessment_competency_listens_discovers_needs(ta)         ->> 'adjusted')::numeric,
    'works_without_close_supervision', (public.assessment_competency_works_without_close_supervision(ta) ->> 'adjusted')::numeric,
    'competes_for_recognition',        (public.assessment_competency_competes_for_recognition(ta)        ->> 'adjusted')::numeric,
    'rapid_rapport_warm',              (public.assessment_competency_rapid_rapport_warm(ta)              ->> 'adjusted')::numeric,
    'cadence_compliance',              (public.assessment_competency_cadence_compliance(ta)              ->> 'adjusted')::numeric,
    'makes_decisions_quickly',         (public.assessment_competency_makes_decisions_quickly(ta)         ->> 'adjusted')::numeric,
    'is_fast_start_oriented',          (public.assessment_competency_is_fast_start_oriented(ta)          ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit',      (public.assessment_competency_has_entrepreneurial_spirit(ta)      ->> 'adjusted')::numeric,
    'receives_coaching',               (public.assessment_competency_receives_coaching(ta)               ->> 'adjusted')::numeric,
    'queue_throughput_discipline',     (public.assessment_competency_queue_throughput_discipline(ta)     ->> 'adjusted')::numeric,
    'attention_to_detail',             (public.assessment_competency_attention_to_detail(ta)             ->> 'adjusted')::numeric,
    'prospects_in_community',          (public.assessment_competency_prospects_in_community(ta)          ->> 'adjusted')::numeric,
    'positively_influences_team',      (public.assessment_competency_positively_influences_team(ta)      ->> 'adjusted')::numeric,
    'routing_judgment',                (public.assessment_competency_routing_judgment(ta)                ->> 'adjusted')::numeric,
    'retention_watchfulness',          (public.assessment_competency_retention_watchfulness(ta)          ->> 'adjusted')::numeric,
    'signal_hwe',                      (public.assessment_signal_hwe(ta)                                 ->> 'adjusted')::numeric,
    'signal_drive_engine',             (public.assessment_signal_drive_engine(ta)                        ->> 'adjusted')::numeric,
    'signal_honesty',                  (public.assessment_signal_honesty(ta)                             ->> 'adjusted')::numeric,
    'signal_overthinker_penalty',      (public.assessment_signal_overthinker_penalty(ta)                 ->> 'adjusted')::numeric
  );

  drive_gated := CASE
    WHEN (s->>'signal_drive_engine')::numeric < 50 THEN 0
    WHEN (s->>'signal_drive_engine')::numeric > 70 THEN (s->>'signal_drive_engine')::numeric
    ELSE ((s->>'signal_drive_engine')::numeric - 50) * ((s->>'signal_drive_engine')::numeric / 20.0)
  END;

  hwe_gated := GREATEST(0, (s->>'signal_hwe')::numeric - 55) * 100.0 / 45.0;

  fit := (s->>'maintains_high_activity')::numeric         * 0.16
       + (s->>'handles_rejection')::numeric               * 0.12
       + (s->>'handles_objections')::numeric              * 0.12
       + (s->>'dials_cold_calls')::numeric                * 0.10
       + drive_gated                                       * 0.08
       + (s->>'analytical')::numeric                      * 0.06
       + (s->>'presents_solutions')::numeric              * 0.07
       + (s->>'listens_discovers_needs')::numeric         * 0.07
       + (s->>'works_without_close_supervision')::numeric * 0.05
       + (s->>'cadence_compliance')::numeric              * 0.05
       + hwe_gated                                         * 0.06
       + (s->>'competes_for_recognition')::numeric        * 0.02
       + (s->>'rapid_rapport_warm')::numeric              * 0.04
       + (s->>'makes_decisions_quickly')::numeric         * 0.04
       + (s->>'signal_honesty')::numeric                  * 0.03
       + (s->>'has_entrepreneurial_spirit')::numeric      * 0.03
       + (s->>'receives_coaching')::numeric               * 0.03
       + (s->>'is_fast_start_oriented')::numeric          * 0.03
       + (s->>'queue_throughput_discipline')::numeric     * 0.02
       + (s->>'attention_to_detail')::numeric             * 0.01
       + (s->>'prospects_in_community')::numeric          * 0.02
       + (s->>'positively_influences_team')::numeric      * 0.02
       + (s->>'signal_overthinker_penalty')::numeric      * (-0.15)
       + (s->>'routing_judgment')::numeric                * (-0.04)
       + (s->>'retention_watchfulness')::numeric          * (-0.04);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_outbound',
    'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v3_9_ps_an_shift_cfr_halved_2026_07_26',
      'changes_from_v3_8', 'CFR weight 0.04 -> 0.02 (over-fire dampening on SIB Achiever/Rockstar over-fires). Paired with PS competency change (RD 0.25 -> 0.20, AN 0.20 -> 0.25) — archetype-anchored to QC-Analyst (Thomas AN 91).',
      'drive_gated', drive_gated,
      'hwe_gated', hwe_gated
    )
  );
END;
$function$;
