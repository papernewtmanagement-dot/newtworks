CREATE OR REPLACE FUNCTION public.assessment_role_fit_aspirant(p_assessment_id uuid)
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
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'aspirant');
  END IF;

  s := jsonb_build_object(
    'has_entrepreneurial_spirit',           (public.assessment_competency_has_entrepreneurial_spirit(ta)           ->> 'adjusted')::numeric,
    'maintains_high_activity',              (public.assessment_competency_maintains_high_activity(ta)              ->> 'adjusted')::numeric,
    'handles_rejection',                    (public.assessment_competency_handles_rejection(ta)                    ->> 'adjusted')::numeric,
    'receives_coaching',                    (public.assessment_competency_receives_coaching(ta)                    ->> 'adjusted')::numeric,
    'composure_under_load',                 (public.assessment_competency_composure_under_load(ta)                 ->> 'adjusted')::numeric,
    'works_without_close_supervision',      (public.assessment_competency_works_without_close_supervision(ta)      ->> 'adjusted')::numeric,
    'competes_for_recognition',             (public.assessment_competency_competes_for_recognition(ta)             ->> 'adjusted')::numeric,
    'makes_decisions_quickly',              (public.assessment_competency_makes_decisions_quickly(ta)              ->> 'adjusted')::numeric,
    'balances_logic_and_emotion_when_hiring', (public.assessment_competency_balances_logic_and_emotion_when_hiring(ta) ->> 'adjusted')::numeric,
    'attention_to_detail',                  (public.assessment_competency_attention_to_detail(ta)                  ->> 'adjusted')::numeric,
    'rapid_rapport_warm',                   (public.assessment_competency_rapid_rapport_warm(ta)                   ->> 'adjusted')::numeric,
    'handles_objections',                   (public.assessment_competency_handles_objections(ta)                   ->> 'adjusted')::numeric,
    'presents_solutions',                   (public.assessment_competency_presents_solutions(ta)                   ->> 'adjusted')::numeric,
    'pivots_to_customer_need',              (public.assessment_competency_pivots_to_customer_need(ta)              ->> 'adjusted')::numeric,
    'cadence_compliance',                   (public.assessment_competency_cadence_compliance(ta)                   ->> 'adjusted')::numeric,
    'analytical',                           (public.assessment_competency_analytical(ta)                           ->> 'adjusted')::numeric,
    'cross_sell_instinct',                  (public.assessment_competency_cross_sell_instinct(ta)                  ->> 'adjusted')::numeric,
    'proactive_touch_discipline',           (public.assessment_competency_proactive_touch_discipline(ta)           ->> 'adjusted')::numeric,
    'listens_discovers_needs',              (public.assessment_competency_listens_discovers_needs(ta)              ->> 'adjusted')::numeric,
    'manages_time_effectively',             (public.assessment_competency_manages_time_effectively(ta)             ->> 'adjusted')::numeric,
    'positively_influences_team',           (public.assessment_competency_positively_influences_team(ta)           ->> 'adjusted')::numeric,
    'retention_watchfulness',               (public.assessment_competency_retention_watchfulness(ta)               ->> 'adjusted')::numeric,
    'is_fast_start_oriented',               (public.assessment_competency_is_fast_start_oriented(ta)               ->> 'adjusted')::numeric,
    'prospects_in_community',               (public.assessment_competency_prospects_in_community(ta)               ->> 'adjusted')::numeric,
    'dials_cold_calls',                     (public.assessment_competency_dials_cold_calls(ta)                     ->> 'adjusted')::numeric,
    'queue_throughput_discipline',          (public.assessment_competency_queue_throughput_discipline(ta)          ->> 'adjusted')::numeric
  );

  fit := (s->>'has_entrepreneurial_spirit')::numeric              * 0.09
       + (s->>'maintains_high_activity')::numeric                 * 0.08
       + (s->>'handles_rejection')::numeric                       * 0.07
       + (s->>'receives_coaching')::numeric                       * 0.07
       + (s->>'composure_under_load')::numeric                    * 0.06
       + (s->>'works_without_close_supervision')::numeric         * 0.06
       + (s->>'competes_for_recognition')::numeric                * 0.06
       + (s->>'makes_decisions_quickly')::numeric                 * 0.05
       + (s->>'balances_logic_and_emotion_when_hiring')::numeric  * 0.04
       + (s->>'attention_to_detail')::numeric                     * 0.04
       + (s->>'rapid_rapport_warm')::numeric                      * 0.04
       + (s->>'handles_objections')::numeric                      * 0.04
       + (s->>'presents_solutions')::numeric                      * 0.04
       + (s->>'pivots_to_customer_need')::numeric                 * 0.04
       + (s->>'cadence_compliance')::numeric                      * 0.03
       + (s->>'analytical')::numeric                              * 0.03
       + (s->>'cross_sell_instinct')::numeric                     * 0.03
       + (s->>'proactive_touch_discipline')::numeric              * 0.03
       + (s->>'listens_discovers_needs')::numeric                 * 0.03
       + (s->>'manages_time_effectively')::numeric                * 0.02
       + (s->>'positively_influences_team')::numeric              * 0.02
       + (s->>'retention_watchfulness')::numeric                  * 0.02
       + (s->>'is_fast_start_oriented')::numeric                  * 0.02
       + (s->>'prospects_in_community')::numeric                  * 0.02
       + (s->>'dials_cold_calls')::numeric                        * 0.02
       + (s->>'queue_throughput_discipline')::numeric             * (-0.05);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'aspirant',
    'adjusted', s,
    'weights', jsonb_build_object(
      'has_entrepreneurial_spirit', 0.09, 'maintains_high_activity', 0.08,
      'handles_rejection', 0.07, 'receives_coaching', 0.07,
      'composure_under_load', 0.06, 'works_without_close_supervision', 0.06,
      'competes_for_recognition', 0.06, 'makes_decisions_quickly', 0.05,
      'balances_logic_and_emotion_when_hiring', 0.04, 'attention_to_detail', 0.04,
      'rapid_rapport_warm', 0.04, 'handles_objections', 0.04,
      'presents_solutions', 0.04, 'pivots_to_customer_need', 0.04,
      'cadence_compliance', 0.03, 'analytical', 0.03,
      'cross_sell_instinct', 0.03, 'proactive_touch_discipline', 0.03,
      'listens_discovers_needs', 0.03, 'manages_time_effectively', 0.02,
      'positively_influences_team', 0.02, 'retention_watchfulness', 0.02,
      'is_fast_start_oriented', 0.02, 'prospects_in_community', 0.02,
      'dials_cold_calls', 0.02
    ),
    'negative_weights', jsonb_build_object(
      'queue_throughput_discipline', -0.05
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.05, 'negative_weight_sum', -0.05, 'net_weight_sum', 1.00,
      'model', 'role_fit_v3_5_realism_tune_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;
