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
    'is_fast_start_oriented',          (public.assessment_competency_is_fast_start_oriented(ta)          ->> 'adjusted')::numeric
  );

  fit := (s->>'attention_to_detail')::numeric             * 0.20
       + (s->>'manages_time_effectively')::numeric        * 0.18
       + (s->>'queue_throughput_discipline')::numeric     * 0.13
       + (s->>'maintains_high_activity')::numeric         * 0.12
       + (s->>'listens_discovers_needs')::numeric         * 0.11
       + (s->>'works_without_close_supervision')::numeric * 0.11
       + (s->>'receives_coaching')::numeric               * 0.11
       + (s->>'cadence_compliance')::numeric              * 0.08
       + (s->>'analytical')::numeric                      * 0.08
       + (s->>'retention_watchfulness')::numeric          * 0.07
       + (s->>'makes_decisions_quickly')::numeric         * 0.07
       + (s->>'positively_influences_team')::numeric      * 0.04
       + (s->>'proactive_touch_discipline')::numeric      * 0.03
       + (s->>'routing_judgment')::numeric                * 0.03
       + (s->>'has_entrepreneurial_spirit')::numeric      * (-0.18)
       + (s->>'competes_for_recognition')::numeric        * (-0.08)
       + (s->>'dials_cold_calls')::numeric                * (-0.04)
       + (s->>'prospects_in_community')::numeric          * (-0.04)
       + (s->>'is_fast_start_oriented')::numeric          * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_support',
    'adjusted', s,
    'weights', jsonb_build_object(
      'attention_to_detail', 0.20, 'manages_time_effectively', 0.18,
      'queue_throughput_discipline', 0.13, 'maintains_high_activity', 0.12,
      'listens_discovers_needs', 0.11, 'works_without_close_supervision', 0.11,
      'receives_coaching', 0.11, 'cadence_compliance', 0.08, 'analytical', 0.08,
      'retention_watchfulness', 0.07, 'makes_decisions_quickly', 0.07,
      'positively_influences_team', 0.04, 'proactive_touch_discipline', 0.03,
      'routing_judgment', 0.03
    ),
    'negative_weights', jsonb_build_object(
      'has_entrepreneurial_spirit', -0.18, 'competes_for_recognition', -0.08,
      'dials_cold_calls', -0.04, 'prospects_in_community', -0.04,
      'is_fast_start_oriented', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.36, 'negative_weight_sum', -0.36, 'net_weight_sum', 1.00,
      'model', 'role_fit_v3_7_hes_penalty_boost_2026_07_25',
      'changes_from_v3_6', 'HES -0.08→-0.18, listens 0.06→0.11, receives_coaching 0.08→0.11, retention_watchfulness 0.05→0.07',
      'rationale', 'Thomas Lynch outlier: HES 76 vs RS-fits avg 52 is cleanest differentiator; boost customer-service positives Thomas scores low on to compensate'
    )
  );
END;
$function$;
