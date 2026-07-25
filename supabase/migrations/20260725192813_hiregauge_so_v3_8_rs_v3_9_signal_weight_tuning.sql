-- SO v3.8: threshold-gated drive_engine + hwe, hardened overthinker penalty
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

  -- Threshold gate for drive_engine: no boost <50; smooth ramp 50-70; raw >70
  drive_gated := CASE
    WHEN (s->>'signal_drive_engine')::numeric < 50 THEN 0
    WHEN (s->>'signal_drive_engine')::numeric > 70 THEN (s->>'signal_drive_engine')::numeric
    ELSE ((s->>'signal_drive_engine')::numeric - 50) * ((s->>'signal_drive_engine')::numeric / 20.0)
  END;

  -- Threshold gate for hwe: character floor 55 subtracted, rescaled to 0-100
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
       + (s->>'competes_for_recognition')::numeric        * 0.04
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
      'model', 'role_fit_v3_8_threshold_gates_2026_07_25',
      'changes_from_v3_7', 'drive_engine 0.06 linear -> 0.08 threshold-gated (0 below 50, smooth ramp 50-70, raw above 70). hwe 0.04 linear -> 0.06 threshold-gated (0 below 55, rescaled 55-100 -> 0-100). overthinker_penalty -0.03 -> -0.15 (hardened).',
      'drive_gated', drive_gated,
      'hwe_gated', hwe_gated
    )
  );
END;
$function$;

-- RS v3.9: concern lifted 0.06 -> 0.10
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
       + (s->>'signal_concern')::numeric                  * 0.10
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
      'model', 'role_fit_v3_9_concern_lift_2026_07_25',
      'changes_from_v3_8', 'signal_concern 0.06 -> 0.10 for stronger empathic-retention lift.'
    )
  );
END;
$function$;
