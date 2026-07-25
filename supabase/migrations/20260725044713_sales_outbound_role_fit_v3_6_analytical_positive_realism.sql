CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_outbound(p_assessment_id uuid)
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
    'retention_watchfulness',          (public.assessment_competency_retention_watchfulness(ta)          ->> 'adjusted')::numeric
  );

  fit := (s->>'maintains_high_activity')::numeric         * 0.20
       + (s->>'handles_rejection')::numeric               * 0.14
       + (s->>'handles_objections')::numeric              * 0.12
       + (s->>'dials_cold_calls')::numeric                * 0.10
       + (s->>'analytical')::numeric                      * 0.08
       + (s->>'presents_solutions')::numeric              * 0.07
       + (s->>'listens_discovers_needs')::numeric         * 0.07
       + (s->>'works_without_close_supervision')::numeric * 0.05
       + (s->>'cadence_compliance')::numeric              * 0.05
       + (s->>'competes_for_recognition')::numeric        * 0.04
       + (s->>'rapid_rapport_warm')::numeric              * 0.04
       + (s->>'makes_decisions_quickly')::numeric         * 0.04
       + (s->>'has_entrepreneurial_spirit')::numeric      * 0.03
       + (s->>'receives_coaching')::numeric               * 0.03
       + (s->>'is_fast_start_oriented')::numeric          * 0.03
       + (s->>'queue_throughput_discipline')::numeric     * 0.03
       + (s->>'attention_to_detail')::numeric             * 0.02
       + (s->>'prospects_in_community')::numeric          * 0.02
       + (s->>'positively_influences_team')::numeric      * 0.02
       + (s->>'routing_judgment')::numeric                * (-0.04)
       + (s->>'retention_watchfulness')::numeric          * (-0.04);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_outbound',
    'adjusted', s,
    'weights', jsonb_build_object(
      'maintains_high_activity', 0.20, 'handles_rejection', 0.14, 'handles_objections', 0.12,
      'dials_cold_calls', 0.10, 'analytical', 0.08, 'presents_solutions', 0.07,
      'listens_discovers_needs', 0.07, 'works_without_close_supervision', 0.05,
      'cadence_compliance', 0.05, 'competes_for_recognition', 0.04,
      'rapid_rapport_warm', 0.04, 'makes_decisions_quickly', 0.04,
      'has_entrepreneurial_spirit', 0.03, 'receives_coaching', 0.03,
      'is_fast_start_oriented', 0.03, 'queue_throughput_discipline', 0.03,
      'attention_to_detail', 0.02, 'prospects_in_community', 0.02, 'positively_influences_team', 0.02
    ),
    'negative_weights', jsonb_build_object(
      'routing_judgment', -0.04, 'retention_watchfulness', -0.04
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.16, 'negative_weight_sum', -0.08, 'net_weight_sum', 1.08,
      'model', 'role_fit_v3_6_analytical_positive_realism_2026_07_25',
      'changes_from_v3_5', 'analytical -0.03 to +0.08, attention_to_detail -0.03 to +0.02, queue_throughput_discipline -0.03 to +0.03, competes_for_recognition 0.06 to 0.04, maintains_high_activity 0.23 to 0.20, handles_rejection 0.16 to 0.14, dials_cold_calls 0.12 to 0.10, presents_solutions 0.08 to 0.07, rapid_rapport_warm 0.05 to 0.04, is_fast_start_oriented 0.04 to 0.03',
      'rationale', 'Analytical is a positive skill for outbound (needs analysis, script comprehension, product knowledge). ATD positive for CRM discipline. QTD positive for prospect list management. Recognition-drive over-weighted for loud-competitive archetype. Formula was designed for cowboy-outbound; missed the analytical-closer variant.'
    )
  );
END;
$function$;
