-- Migration: role_fit_v3_5_realism_tune — five role_fits (aspirant held)
-- 2026-07-24

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
    'presents_solutions',              (public.assessment_competency_presents_solutions(ta)              ->> 'adjusted')::numeric,
    'listens_discovers_needs',         (public.assessment_competency_listens_discovers_needs(ta)         ->> 'adjusted')::numeric,
    'competes_for_recognition',        (public.assessment_competency_competes_for_recognition(ta)        ->> 'adjusted')::numeric,
    'rapid_rapport_warm',              (public.assessment_competency_rapid_rapport_warm(ta)              ->> 'adjusted')::numeric,
    'cadence_compliance',              (public.assessment_competency_cadence_compliance(ta)              ->> 'adjusted')::numeric,
    'works_without_close_supervision', (public.assessment_competency_works_without_close_supervision(ta) ->> 'adjusted')::numeric,
    'is_fast_start_oriented',          (public.assessment_competency_is_fast_start_oriented(ta)          ->> 'adjusted')::numeric,
    'makes_decisions_quickly',         (public.assessment_competency_makes_decisions_quickly(ta)         ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit',      (public.assessment_competency_has_entrepreneurial_spirit(ta)      ->> 'adjusted')::numeric,
    'receives_coaching',               (public.assessment_competency_receives_coaching(ta)               ->> 'adjusted')::numeric,
    'prospects_in_community',          (public.assessment_competency_prospects_in_community(ta)          ->> 'adjusted')::numeric,
    'positively_influences_team',      (public.assessment_competency_positively_influences_team(ta)      ->> 'adjusted')::numeric,
    'attention_to_detail',             (public.assessment_competency_attention_to_detail(ta)             ->> 'adjusted')::numeric,
    'analytical',                      (public.assessment_competency_analytical(ta)                      ->> 'adjusted')::numeric,
    'routing_judgment',                (public.assessment_competency_routing_judgment(ta)                ->> 'adjusted')::numeric,
    'queue_throughput_discipline',     (public.assessment_competency_queue_throughput_discipline(ta)     ->> 'adjusted')::numeric,
    'retention_watchfulness',          (public.assessment_competency_retention_watchfulness(ta)          ->> 'adjusted')::numeric
  );

  fit := (s->>'maintains_high_activity')::numeric         * 0.23
       + (s->>'handles_rejection')::numeric               * 0.16
       + (s->>'handles_objections')::numeric              * 0.12
       + (s->>'dials_cold_calls')::numeric                * 0.12
       + (s->>'presents_solutions')::numeric              * 0.08
       + (s->>'listens_discovers_needs')::numeric         * 0.07
       + (s->>'competes_for_recognition')::numeric        * 0.06
       + (s->>'rapid_rapport_warm')::numeric              * 0.05
       + (s->>'cadence_compliance')::numeric              * 0.05
       + (s->>'works_without_close_supervision')::numeric * 0.05
       + (s->>'is_fast_start_oriented')::numeric          * 0.04
       + (s->>'makes_decisions_quickly')::numeric         * 0.04
       + (s->>'has_entrepreneurial_spirit')::numeric      * 0.03
       + (s->>'receives_coaching')::numeric               * 0.03
       + (s->>'prospects_in_community')::numeric          * 0.02
       + (s->>'positively_influences_team')::numeric      * 0.02
       + (s->>'attention_to_detail')::numeric             * (-0.03)
       + (s->>'analytical')::numeric                      * (-0.03)
       + (s->>'routing_judgment')::numeric                * (-0.04)
       + (s->>'queue_throughput_discipline')::numeric     * (-0.03)
       + (s->>'retention_watchfulness')::numeric          * (-0.04);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_outbound',
    'adjusted', s,
    'weights', jsonb_build_object(
      'maintains_high_activity', 0.23, 'handles_rejection', 0.16, 'handles_objections', 0.12,
      'dials_cold_calls', 0.12, 'presents_solutions', 0.08, 'listens_discovers_needs', 0.07,
      'competes_for_recognition', 0.06, 'rapid_rapport_warm', 0.05, 'cadence_compliance', 0.05,
      'works_without_close_supervision', 0.05, 'is_fast_start_oriented', 0.04,
      'makes_decisions_quickly', 0.04, 'has_entrepreneurial_spirit', 0.03,
      'receives_coaching', 0.03, 'prospects_in_community', 0.02, 'positively_influences_team', 0.02
    ),
    'negative_weights', jsonb_build_object(
      'attention_to_detail', -0.03, 'analytical', -0.03, 'routing_judgment', -0.04,
      'queue_throughput_discipline', -0.03, 'retention_watchfulness', -0.04
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.17, 'negative_weight_sum', -0.17, 'net_weight_sum', 1.00,
      'model', 'role_fit_v3_5_realism_tune_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_in_book(p_assessment_id uuid)
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
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_in_book');
  END IF;

  s := jsonb_build_object(
    'cross_sell_instinct',        (public.assessment_competency_cross_sell_instinct(ta)        ->> 'adjusted')::numeric,
    'listens_discovers_needs',    (public.assessment_competency_listens_discovers_needs(ta)    ->> 'adjusted')::numeric,
    'proactive_touch_discipline', (public.assessment_competency_proactive_touch_discipline(ta) ->> 'adjusted')::numeric,
    'retention_watchfulness',     (public.assessment_competency_retention_watchfulness(ta)     ->> 'adjusted')::numeric,
    'presents_solutions',         (public.assessment_competency_presents_solutions(ta)         ->> 'adjusted')::numeric,
    'handles_objections',         (public.assessment_competency_handles_objections(ta)         ->> 'adjusted')::numeric,
    'rapid_rapport_warm',         (public.assessment_competency_rapid_rapport_warm(ta)         ->> 'adjusted')::numeric,
    'cadence_compliance',         (public.assessment_competency_cadence_compliance(ta)         ->> 'adjusted')::numeric,
    'pivots_to_customer_need',    (public.assessment_competency_pivots_to_customer_need(ta)    ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)          ->> 'adjusted')::numeric,
    'competes_for_recognition',   (public.assessment_competency_competes_for_recognition(ta)   ->> 'adjusted')::numeric,
    'handles_rejection',          (public.assessment_competency_handles_rejection(ta)          ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta) ->> 'adjusted')::numeric,
    'maintains_high_activity',    (public.assessment_competency_maintains_high_activity(ta)    ->> 'adjusted')::numeric,
    'dials_cold_calls',           (public.assessment_competency_dials_cold_calls(ta)           ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit', (public.assessment_competency_has_entrepreneurial_spirit(ta) ->> 'adjusted')::numeric,
    'is_fast_start_oriented',     (public.assessment_competency_is_fast_start_oriented(ta)     ->> 'adjusted')::numeric,
    'prospects_in_community',     (public.assessment_competency_prospects_in_community(ta)     ->> 'adjusted')::numeric
  );

  fit := (s->>'cross_sell_instinct')::numeric        * 0.21
       + (s->>'listens_discovers_needs')::numeric    * 0.15
       + (s->>'proactive_touch_discipline')::numeric * 0.12
       + (s->>'retention_watchfulness')::numeric     * 0.10
       + (s->>'presents_solutions')::numeric         * 0.10
       + (s->>'handles_objections')::numeric         * 0.09
       + (s->>'rapid_rapport_warm')::numeric         * 0.07
       + (s->>'cadence_compliance')::numeric         * 0.06
       + (s->>'pivots_to_customer_need')::numeric    * 0.05
       + (s->>'receives_coaching')::numeric          * 0.05
       + (s->>'competes_for_recognition')::numeric   * 0.03
       + (s->>'handles_rejection')::numeric          * 0.03
       + (s->>'positively_influences_team')::numeric * 0.03
       + (s->>'maintains_high_activity')::numeric    * 0.03
       + (s->>'dials_cold_calls')::numeric           * (-0.03)
       + (s->>'has_entrepreneurial_spirit')::numeric * (-0.03)
       + (s->>'is_fast_start_oriented')::numeric     * (-0.03)
       + (s->>'prospects_in_community')::numeric     * (-0.03);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_in_book',
    'adjusted', s,
    'weights', jsonb_build_object(
      'cross_sell_instinct', 0.21, 'listens_discovers_needs', 0.15, 'proactive_touch_discipline', 0.12,
      'retention_watchfulness', 0.10, 'presents_solutions', 0.10, 'handles_objections', 0.09,
      'rapid_rapport_warm', 0.07, 'cadence_compliance', 0.06, 'pivots_to_customer_need', 0.05,
      'receives_coaching', 0.05, 'competes_for_recognition', 0.03, 'handles_rejection', 0.03,
      'positively_influences_team', 0.03, 'maintains_high_activity', 0.03
    ),
    'negative_weights', jsonb_build_object(
      'dials_cold_calls', -0.03, 'has_entrepreneurial_spirit', -0.03,
      'is_fast_start_oriented', -0.03, 'prospects_in_community', -0.03
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.12, 'negative_weight_sum', -0.12, 'net_weight_sum', 1.00,
      'model', 'role_fit_v3_5_realism_tune_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_inbound(p_assessment_id uuid)
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
       + (s->>'dials_cold_calls')::numeric                * (-0.04)
       + (s->>'prospects_in_community')::numeric          * (-0.04)
       + (s->>'has_entrepreneurial_spirit')::numeric      * (-0.03)
       + (s->>'attention_to_detail')::numeric             * (-0.02)
       + (s->>'analytical')::numeric                      * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_inbound',
    'adjusted', s,
    'weights', jsonb_build_object(
      'rapid_rapport_warm', 0.20, 'listens_discovers_needs', 0.15, 'presents_solutions', 0.13,
      'handles_objections', 0.11, 'composure_under_load', 0.08, 'makes_decisions_quickly', 0.07,
      'cross_sell_instinct', 0.06, 'cadence_compliance', 0.06, 'pivots_to_customer_need', 0.05,
      'receives_coaching', 0.05, 'retention_watchfulness', 0.04, 'works_without_close_supervision', 0.04,
      'maintains_high_activity', 0.04, 'handles_rejection', 0.04, 'positively_influences_team', 0.03
    ),
    'negative_weights', jsonb_build_object(
      'dials_cold_calls', -0.04, 'prospects_in_community', -0.04,
      'has_entrepreneurial_spirit', -0.03, 'attention_to_detail', -0.02, 'analytical', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.15, 'negative_weight_sum', -0.15, 'net_weight_sum', 1.00,
      'model', 'role_fit_v3_5_realism_tune_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;

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
    'queue_throughput_discipline',     (public.assessment_competency_queue_throughput_discipline(ta)     ->> 'adjusted')::numeric,
    'works_without_close_supervision', (public.assessment_competency_works_without_close_supervision(ta) ->> 'adjusted')::numeric,
    'makes_decisions_quickly',         (public.assessment_competency_makes_decisions_quickly(ta)         ->> 'adjusted')::numeric,
    'analytical',                      (public.assessment_competency_analytical(ta)                      ->> 'adjusted')::numeric,
    'receives_coaching',               (public.assessment_competency_receives_coaching(ta)               ->> 'adjusted')::numeric,
    'positively_influences_team',      (public.assessment_competency_positively_influences_team(ta)      ->> 'adjusted')::numeric,
    'cadence_compliance',              (public.assessment_competency_cadence_compliance(ta)              ->> 'adjusted')::numeric,
    'listens_discovers_needs',         (public.assessment_competency_listens_discovers_needs(ta)         ->> 'adjusted')::numeric,
    'proactive_touch_discipline',      (public.assessment_competency_proactive_touch_discipline(ta)      ->> 'adjusted')::numeric,
    'retention_watchfulness',          (public.assessment_competency_retention_watchfulness(ta)          ->> 'adjusted')::numeric,
    'routing_judgment',                (public.assessment_competency_routing_judgment(ta)                ->> 'adjusted')::numeric,
    'competes_for_recognition',        (public.assessment_competency_competes_for_recognition(ta)        ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit',      (public.assessment_competency_has_entrepreneurial_spirit(ta)      ->> 'adjusted')::numeric,
    'rapid_rapport_warm',              (public.assessment_competency_rapid_rapport_warm(ta)              ->> 'adjusted')::numeric,
    'dials_cold_calls',                (public.assessment_competency_dials_cold_calls(ta)                ->> 'adjusted')::numeric,
    'prospects_in_community',          (public.assessment_competency_prospects_in_community(ta)          ->> 'adjusted')::numeric,
    'is_fast_start_oriented',          (public.assessment_competency_is_fast_start_oriented(ta)          ->> 'adjusted')::numeric
  );

  fit := (s->>'attention_to_detail')::numeric             * 0.24
       + (s->>'manages_time_effectively')::numeric        * 0.21
       + (s->>'queue_throughput_discipline')::numeric     * 0.15
       + (s->>'works_without_close_supervision')::numeric * 0.13
       + (s->>'makes_decisions_quickly')::numeric         * 0.09
       + (s->>'analytical')::numeric                      * 0.09
       + (s->>'receives_coaching')::numeric               * 0.06
       + (s->>'positively_influences_team')::numeric      * 0.05
       + (s->>'cadence_compliance')::numeric              * 0.05
       + (s->>'listens_discovers_needs')::numeric         * 0.04
       + (s->>'proactive_touch_discipline')::numeric      * 0.03
       + (s->>'retention_watchfulness')::numeric          * 0.03
       + (s->>'routing_judgment')::numeric                * 0.03
       + (s->>'competes_for_recognition')::numeric        * (-0.05)
       + (s->>'has_entrepreneurial_spirit')::numeric      * (-0.05)
       + (s->>'dials_cold_calls')::numeric                * (-0.03)
       + (s->>'prospects_in_community')::numeric          * (-0.03)
       + (s->>'rapid_rapport_warm')::numeric              * (-0.02)
       + (s->>'is_fast_start_oriented')::numeric          * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_support',
    'adjusted', s,
    'weights', jsonb_build_object(
      'attention_to_detail', 0.24, 'manages_time_effectively', 0.21, 'queue_throughput_discipline', 0.15,
      'works_without_close_supervision', 0.13, 'makes_decisions_quickly', 0.09, 'analytical', 0.09,
      'receives_coaching', 0.06, 'positively_influences_team', 0.05, 'cadence_compliance', 0.05,
      'listens_discovers_needs', 0.04, 'proactive_touch_discipline', 0.03,
      'retention_watchfulness', 0.03, 'routing_judgment', 0.03
    ),
    'negative_weights', jsonb_build_object(
      'competes_for_recognition', -0.05, 'has_entrepreneurial_spirit', -0.05,
      'dials_cold_calls', -0.03, 'prospects_in_community', -0.03,
      'rapid_rapport_warm', -0.02, 'is_fast_start_oriented', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.20, 'negative_weight_sum', -0.20, 'net_weight_sum', 1.00,
      'model', 'role_fit_v3_5_realism_tune_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.assessment_role_fit_retention_escalation(p_assessment_id uuid)
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
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_escalation');
  END IF;

  s := jsonb_build_object(
    'composure_under_load',       (public.assessment_competency_composure_under_load(ta)       ->> 'adjusted')::numeric,
    'handles_objections',         (public.assessment_competency_handles_objections(ta)         ->> 'adjusted')::numeric,
    'listens_discovers_needs',    (public.assessment_competency_listens_discovers_needs(ta)    ->> 'adjusted')::numeric,
    'retention_watchfulness',     (public.assessment_competency_retention_watchfulness(ta)     ->> 'adjusted')::numeric,
    'presents_solutions',         (public.assessment_competency_presents_solutions(ta)         ->> 'adjusted')::numeric,
    'proactive_touch_discipline', (public.assessment_competency_proactive_touch_discipline(ta) ->> 'adjusted')::numeric,
    'rapid_rapport_warm',         (public.assessment_competency_rapid_rapport_warm(ta)         ->> 'adjusted')::numeric,
    'handles_rejection',          (public.assessment_competency_handles_rejection(ta)          ->> 'adjusted')::numeric,
    'analytical',                 (public.assessment_competency_analytical(ta)                 ->> 'adjusted')::numeric,
    'attention_to_detail',        (public.assessment_competency_attention_to_detail(ta)        ->> 'adjusted')::numeric,
    'makes_decisions_quickly',    (public.assessment_competency_makes_decisions_quickly(ta)    ->> 'adjusted')::numeric,
    'pivots_to_customer_need',    (public.assessment_competency_pivots_to_customer_need(ta)    ->> 'adjusted')::numeric,
    'routing_judgment',           (public.assessment_competency_routing_judgment(ta)           ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)          ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta) ->> 'adjusted')::numeric,
    'competes_for_recognition',   (public.assessment_competency_competes_for_recognition(ta)   ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit', (public.assessment_competency_has_entrepreneurial_spirit(ta) ->> 'adjusted')::numeric,
    'prospects_in_community',     (public.assessment_competency_prospects_in_community(ta)     ->> 'adjusted')::numeric,
    'dials_cold_calls',           (public.assessment_competency_dials_cold_calls(ta)           ->> 'adjusted')::numeric,
    'is_fast_start_oriented',     (public.assessment_competency_is_fast_start_oriented(ta)     ->> 'adjusted')::numeric
  );

  fit := (s->>'composure_under_load')::numeric       * 0.20
       + (s->>'handles_objections')::numeric         * 0.15
       + (s->>'listens_discovers_needs')::numeric    * 0.11
       + (s->>'retention_watchfulness')::numeric     * 0.10
       + (s->>'presents_solutions')::numeric         * 0.10
       + (s->>'proactive_touch_discipline')::numeric * 0.08
       + (s->>'rapid_rapport_warm')::numeric         * 0.07
       + (s->>'handles_rejection')::numeric          * 0.06
       + (s->>'analytical')::numeric                 * 0.06
       + (s->>'attention_to_detail')::numeric        * 0.04
       + (s->>'makes_decisions_quickly')::numeric    * 0.04
       + (s->>'pivots_to_customer_need')::numeric    * 0.04
       + (s->>'routing_judgment')::numeric           * 0.03
       + (s->>'receives_coaching')::numeric          * 0.02
       + (s->>'positively_influences_team')::numeric * 0.02
       + (s->>'competes_for_recognition')::numeric   * (-0.03)
       + (s->>'has_entrepreneurial_spirit')::numeric * (-0.03)
       + (s->>'prospects_in_community')::numeric     * (-0.02)
       + (s->>'dials_cold_calls')::numeric           * (-0.02)
       + (s->>'is_fast_start_oriented')::numeric     * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_escalation',
    'adjusted', s,
    'weights', jsonb_build_object(
      'composure_under_load', 0.20, 'handles_objections', 0.15, 'listens_discovers_needs', 0.11,
      'retention_watchfulness', 0.10, 'presents_solutions', 0.10, 'proactive_touch_discipline', 0.08,
      'rapid_rapport_warm', 0.07, 'handles_rejection', 0.06, 'analytical', 0.06,
      'attention_to_detail', 0.04, 'makes_decisions_quickly', 0.04, 'pivots_to_customer_need', 0.04,
      'routing_judgment', 0.03, 'receives_coaching', 0.02, 'positively_influences_team', 0.02
    ),
    'negative_weights', jsonb_build_object(
      'competes_for_recognition', -0.03, 'has_entrepreneurial_spirit', -0.03,
      'prospects_in_community', -0.02, 'dials_cold_calls', -0.02, 'is_fast_start_oriented', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.12, 'negative_weight_sum', -0.12, 'net_weight_sum', 1.00,
      'model', 'role_fit_v3_5_realism_tune_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;
