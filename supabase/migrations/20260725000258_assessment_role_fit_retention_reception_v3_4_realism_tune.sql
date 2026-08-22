CREATE OR REPLACE FUNCTION public.assessment_role_fit_retention_reception(p_assessment_id uuid)
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
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_reception');
  END IF;

  s := jsonb_build_object(
    'rapid_rapport_warm',         (public.assessment_competency_rapid_rapport_warm(ta)        ->> 'adjusted')::numeric,
    'listens_discovers_needs',    (public.assessment_competency_listens_discovers_needs(ta)   ->> 'adjusted')::numeric,
    'composure_under_load',       (public.assessment_competency_composure_under_load(ta)      ->> 'adjusted')::numeric,
    'routing_judgment',           (public.assessment_competency_routing_judgment(ta)          ->> 'adjusted')::numeric,
    'pivots_to_customer_need',    (public.assessment_competency_pivots_to_customer_need(ta)   ->> 'adjusted')::numeric,
    'handles_objections',         (public.assessment_competency_handles_objections(ta)        ->> 'adjusted')::numeric,
    'queue_throughput_discipline',(public.assessment_competency_queue_throughput_discipline(ta)->> 'adjusted')::numeric,
    'makes_decisions_quickly',    (public.assessment_competency_makes_decisions_quickly(ta)   ->> 'adjusted')::numeric,
    'attention_to_detail',        (public.assessment_competency_attention_to_detail(ta)       ->> 'adjusted')::numeric,
    'retention_watchfulness',     (public.assessment_competency_retention_watchfulness(ta)    ->> 'adjusted')::numeric,
    'manages_time_effectively',   (public.assessment_competency_manages_time_effectively(ta)  ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'cadence_compliance',         (public.assessment_competency_cadence_compliance(ta)        ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric,
    'competes_for_recognition',   (public.assessment_competency_competes_for_recognition(ta)  ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit', (public.assessment_competency_has_entrepreneurial_spirit(ta)->> 'adjusted')::numeric,
    'dials_cold_calls',           (public.assessment_competency_dials_cold_calls(ta)          ->> 'adjusted')::numeric,
    'prospects_in_community',     (public.assessment_competency_prospects_in_community(ta)    ->> 'adjusted')::numeric,
    'is_fast_start_oriented',     (public.assessment_competency_is_fast_start_oriented(ta)    ->> 'adjusted')::numeric
  );

  fit := (s->>'rapid_rapport_warm')::numeric         * 0.18
       + (s->>'listens_discovers_needs')::numeric    * 0.15
       + (s->>'composure_under_load')::numeric       * 0.12
       + (s->>'routing_judgment')::numeric           * 0.11
       + (s->>'pivots_to_customer_need')::numeric    * 0.10
       + (s->>'handles_objections')::numeric         * 0.08
       + (s->>'queue_throughput_discipline')::numeric* 0.08
       + (s->>'makes_decisions_quickly')::numeric    * 0.07
       + (s->>'attention_to_detail')::numeric        * 0.06
       + (s->>'retention_watchfulness')::numeric     * 0.05
       + (s->>'manages_time_effectively')::numeric   * 0.05
       + (s->>'receives_coaching')::numeric          * 0.05
       + (s->>'cadence_compliance')::numeric         * 0.04
       + (s->>'positively_influences_team')::numeric * 0.04
       + (s->>'competes_for_recognition')::numeric   * (-0.05)
       + (s->>'has_entrepreneurial_spirit')::numeric * (-0.05)
       + (s->>'dials_cold_calls')::numeric           * (-0.03)
       + (s->>'prospects_in_community')::numeric     * (-0.03)
       + (s->>'is_fast_start_oriented')::numeric     * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_reception',
    'adjusted', s,
    'weights', jsonb_build_object(
      'rapid_rapport_warm', 0.18, 'listens_discovers_needs', 0.15, 'composure_under_load', 0.12,
      'routing_judgment', 0.11, 'pivots_to_customer_need', 0.10, 'handles_objections', 0.08,
      'queue_throughput_discipline', 0.08, 'makes_decisions_quickly', 0.07, 'attention_to_detail', 0.06,
      'retention_watchfulness', 0.05, 'manages_time_effectively', 0.05, 'receives_coaching', 0.05,
      'cadence_compliance', 0.04, 'positively_influences_team', 0.04
    ),
    'negative_weights', jsonb_build_object(
      'competes_for_recognition', -0.05, 'has_entrepreneurial_spirit', -0.05, 'dials_cold_calls', -0.03,
      'prospects_in_community', -0.03, 'is_fast_start_oriented', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.18, 'negative_weight_sum', -0.18, 'net_weight_sum', 1.00,
      'model', 'role_fit_v3_4_realism_tune_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;
