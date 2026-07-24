-- Role-fit v3.2 — add negative weights.
-- Some competencies actively pull down fit for a role because they signal the person
-- will burn out, disrupt, or drift out. Peter's example: high Competes for Recognition +
-- Has Entrepreneurial Spirit is a red flag for pure Reception fit.
--
-- Structure: positive_weights sum to 1.00 per role (unchanged from v3.1).
-- negative_weights are stored as negative numbers, subtract from fit.
-- Max fit = 100 (all positives at 100, all negatives at 0).
-- Min raw fit = 100 * sum(negative_weights) — always clamped to 0.
-- Still blind to how the adjusted score was produced.

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
    'maintains_high_activity',        (public.assessment_competency_maintains_high_activity(ta)       ->> 'adjusted')::numeric,
    'handles_rejection',              (public.assessment_competency_handles_rejection(ta)             ->> 'adjusted')::numeric,
    'handles_objections',             (public.assessment_competency_handles_objections(ta)            ->> 'adjusted')::numeric,
    'dials_cold_calls',               (public.assessment_competency_dials_cold_calls(ta)              ->> 'adjusted')::numeric,
    'presents_solutions',             (public.assessment_competency_presents_solutions(ta)            ->> 'adjusted')::numeric,
    'listens_discovers_needs',        (public.assessment_competency_listens_discovers_needs(ta)       ->> 'adjusted')::numeric,
    'cadence_compliance',             (public.assessment_competency_cadence_compliance(ta)            ->> 'adjusted')::numeric,
    'works_without_close_supervision',(public.assessment_competency_works_without_close_supervision(ta)->> 'adjusted')::numeric,
    'receives_coaching',              (public.assessment_competency_receives_coaching(ta)             ->> 'adjusted')::numeric,
    'prospects_in_community',         (public.assessment_competency_prospects_in_community(ta)        ->> 'adjusted')::numeric,
    'positively_influences_team',     (public.assessment_competency_positively_influences_team(ta)    ->> 'adjusted')::numeric,
    'attention_to_detail',            (public.assessment_competency_attention_to_detail(ta)           ->> 'adjusted')::numeric,
    'analytical',                     (public.assessment_competency_analytical(ta)                    ->> 'adjusted')::numeric
  );

  -- Negatives: perfectionism + over-analysis kill cold-outreach volume.
  fit := (s->>'maintains_high_activity')::numeric        * 0.22
       + (s->>'handles_rejection')::numeric              * 0.16
       + (s->>'handles_objections')::numeric             * 0.12
       + (s->>'dials_cold_calls')::numeric               * 0.10
       + (s->>'presents_solutions')::numeric             * 0.08
       + (s->>'listens_discovers_needs')::numeric        * 0.07
       + (s->>'cadence_compliance')::numeric             * 0.06
       + (s->>'works_without_close_supervision')::numeric* 0.06
       + (s->>'receives_coaching')::numeric              * 0.05
       + (s->>'prospects_in_community')::numeric         * 0.04
       + (s->>'positively_influences_team')::numeric     * 0.04
       + (s->>'attention_to_detail')::numeric            * (-0.03)
       + (s->>'analytical')::numeric                     * (-0.03);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_outbound',
    'adjusted', s,
    'weights', jsonb_build_object(
      'maintains_high_activity', 0.22,
      'handles_rejection', 0.16,
      'handles_objections', 0.12,
      'dials_cold_calls', 0.10,
      'presents_solutions', 0.08,
      'listens_discovers_needs', 0.07,
      'cadence_compliance', 0.06,
      'works_without_close_supervision', 0.06,
      'receives_coaching', 0.05,
      'prospects_in_community', 0.04,
      'positively_influences_team', 0.04
    ),
    'negative_weights', jsonb_build_object(
      'attention_to_detail', -0.03,
      'analytical', -0.03
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.00,
      'negative_weight_sum', -0.06,
      'model', 'role_fit_v3_2_with_negatives_2026_07_24',
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
    'rapid_rapport_warm',         (public.assessment_competency_rapid_rapport_warm(ta)        ->> 'adjusted')::numeric,
    'listens_discovers_needs',    (public.assessment_competency_listens_discovers_needs(ta)   ->> 'adjusted')::numeric,
    'presents_solutions',         (public.assessment_competency_presents_solutions(ta)        ->> 'adjusted')::numeric,
    'handles_objections',         (public.assessment_competency_handles_objections(ta)        ->> 'adjusted')::numeric,
    'cadence_compliance',         (public.assessment_competency_cadence_compliance(ta)        ->> 'adjusted')::numeric,
    'makes_decisions_quickly',    (public.assessment_competency_makes_decisions_quickly(ta)   ->> 'adjusted')::numeric,
    'pivots_to_customer_need',    (public.assessment_competency_pivots_to_customer_need(ta)   ->> 'adjusted')::numeric,
    'maintains_high_activity',    (public.assessment_competency_maintains_high_activity(ta)   ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'cross_sell_instinct',        (public.assessment_competency_cross_sell_instinct(ta)       ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric,
    'handles_rejection',          (public.assessment_competency_handles_rejection(ta)         ->> 'adjusted')::numeric,
    'attention_to_detail',        (public.assessment_competency_attention_to_detail(ta)       ->> 'adjusted')::numeric,
    'analytical',                 (public.assessment_competency_analytical(ta)                ->> 'adjusted')::numeric
  );

  -- Negatives (softer than outbound because inbound rewards some care): perfectionists slow
  -- the close on engaged warm buyers; over-analytical types stall on decisive customers.
  fit := (s->>'rapid_rapport_warm')::numeric         * 0.20
       + (s->>'listens_discovers_needs')::numeric    * 0.15
       + (s->>'presents_solutions')::numeric         * 0.14
       + (s->>'handles_objections')::numeric         * 0.12
       + (s->>'cadence_compliance')::numeric         * 0.08
       + (s->>'makes_decisions_quickly')::numeric    * 0.06
       + (s->>'pivots_to_customer_need')::numeric    * 0.05
       + (s->>'maintains_high_activity')::numeric    * 0.05
       + (s->>'receives_coaching')::numeric          * 0.05
       + (s->>'cross_sell_instinct')::numeric        * 0.04
       + (s->>'positively_influences_team')::numeric * 0.03
       + (s->>'handles_rejection')::numeric          * 0.03
       + (s->>'attention_to_detail')::numeric        * (-0.02)
       + (s->>'analytical')::numeric                 * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_inbound',
    'adjusted', s,
    'weights', jsonb_build_object(
      'rapid_rapport_warm', 0.20,
      'listens_discovers_needs', 0.15,
      'presents_solutions', 0.14,
      'handles_objections', 0.12,
      'cadence_compliance', 0.08,
      'makes_decisions_quickly', 0.06,
      'pivots_to_customer_need', 0.05,
      'maintains_high_activity', 0.05,
      'receives_coaching', 0.05,
      'cross_sell_instinct', 0.04,
      'positively_influences_team', 0.03,
      'handles_rejection', 0.03
    ),
    'negative_weights', jsonb_build_object(
      'attention_to_detail', -0.02,
      'analytical', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.00,
      'negative_weight_sum', -0.04,
      'model', 'role_fit_v3_2_with_negatives_2026_07_24',
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
    'cross_sell_instinct',        (public.assessment_competency_cross_sell_instinct(ta)       ->> 'adjusted')::numeric,
    'listens_discovers_needs',    (public.assessment_competency_listens_discovers_needs(ta)   ->> 'adjusted')::numeric,
    'proactive_touch_discipline', (public.assessment_competency_proactive_touch_discipline(ta)->> 'adjusted')::numeric,
    'retention_watchfulness',     (public.assessment_competency_retention_watchfulness(ta)    ->> 'adjusted')::numeric,
    'presents_solutions',         (public.assessment_competency_presents_solutions(ta)        ->> 'adjusted')::numeric,
    'handles_objections',         (public.assessment_competency_handles_objections(ta)        ->> 'adjusted')::numeric,
    'rapid_rapport_warm',         (public.assessment_competency_rapid_rapport_warm(ta)        ->> 'adjusted')::numeric,
    'cadence_compliance',         (public.assessment_competency_cadence_compliance(ta)        ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'maintains_high_activity',    (public.assessment_competency_maintains_high_activity(ta)   ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric,
    'competes_for_recognition',   (public.assessment_competency_competes_for_recognition(ta)  ->> 'adjusted')::numeric,
    'dials_cold_calls',           (public.assessment_competency_dials_cold_calls(ta)          ->> 'adjusted')::numeric,
    'prospects_in_community',     (public.assessment_competency_prospects_in_community(ta)    ->> 'adjusted')::numeric
  );

  -- Negatives: in-book is quiet steady cross-sell work on the existing book. Hunter-shape
  -- signals (recognition-seeking, cold-call inclination, community prospecting) mean the
  -- person will chafe at working an existing book and want to chase new instead.
  fit := (s->>'cross_sell_instinct')::numeric        * 0.20
       + (s->>'listens_discovers_needs')::numeric    * 0.15
       + (s->>'proactive_touch_discipline')::numeric * 0.12
       + (s->>'retention_watchfulness')::numeric     * 0.10
       + (s->>'presents_solutions')::numeric         * 0.10
       + (s->>'handles_objections')::numeric         * 0.08
       + (s->>'rapid_rapport_warm')::numeric         * 0.06
       + (s->>'cadence_compliance')::numeric         * 0.06
       + (s->>'receives_coaching')::numeric          * 0.05
       + (s->>'maintains_high_activity')::numeric    * 0.04
       + (s->>'positively_influences_team')::numeric * 0.04
       + (s->>'competes_for_recognition')::numeric   * (-0.03)
       + (s->>'dials_cold_calls')::numeric           * (-0.03)
       + (s->>'prospects_in_community')::numeric     * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_in_book',
    'adjusted', s,
    'weights', jsonb_build_object(
      'cross_sell_instinct', 0.20,
      'listens_discovers_needs', 0.15,
      'proactive_touch_discipline', 0.12,
      'retention_watchfulness', 0.10,
      'presents_solutions', 0.10,
      'handles_objections', 0.08,
      'rapid_rapport_warm', 0.06,
      'cadence_compliance', 0.06,
      'receives_coaching', 0.05,
      'maintains_high_activity', 0.04,
      'positively_influences_team', 0.04
    ),
    'negative_weights', jsonb_build_object(
      'competes_for_recognition', -0.03,
      'dials_cold_calls', -0.03,
      'prospects_in_community', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.00,
      'negative_weight_sum', -0.08,
      'model', 'role_fit_v3_2_with_negatives_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;


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
    'makes_decisions_quickly',    (public.assessment_competency_makes_decisions_quickly(ta)   ->> 'adjusted')::numeric,
    'queue_throughput_discipline',(public.assessment_competency_queue_throughput_discipline(ta)->> 'adjusted')::numeric,
    'attention_to_detail',        (public.assessment_competency_attention_to_detail(ta)       ->> 'adjusted')::numeric,
    'manages_time_effectively',   (public.assessment_competency_manages_time_effectively(ta)  ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric,
    'competes_for_recognition',   (public.assessment_competency_competes_for_recognition(ta)  ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit', (public.assessment_competency_has_entrepreneurial_spirit(ta)->> 'adjusted')::numeric,
    'dials_cold_calls',           (public.assessment_competency_dials_cold_calls(ta)          ->> 'adjusted')::numeric,
    'prospects_in_community',     (public.assessment_competency_prospects_in_community(ta)    ->> 'adjusted')::numeric,
    'is_fast_start_oriented',     (public.assessment_competency_is_fast_start_oriented(ta)    ->> 'adjusted')::numeric
  );

  -- Negatives (Peter's example role — biggest set): Reception is invisible service work.
  -- Recognition-seeking, entrepreneurial ambition, hunter/prospector instinct, or high
  -- velocity-orientation all signal the person will burn out or push out of the role.
  fit := (s->>'rapid_rapport_warm')::numeric         * 0.18
       + (s->>'listens_discovers_needs')::numeric    * 0.14
       + (s->>'composure_under_load')::numeric       * 0.12
       + (s->>'routing_judgment')::numeric           * 0.12
       + (s->>'pivots_to_customer_need')::numeric    * 0.10
       + (s->>'makes_decisions_quickly')::numeric    * 0.08
       + (s->>'queue_throughput_discipline')::numeric* 0.08
       + (s->>'attention_to_detail')::numeric        * 0.06
       + (s->>'manages_time_effectively')::numeric   * 0.04
       + (s->>'receives_coaching')::numeric          * 0.04
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
      'rapid_rapport_warm', 0.18,
      'listens_discovers_needs', 0.14,
      'composure_under_load', 0.12,
      'routing_judgment', 0.12,
      'pivots_to_customer_need', 0.10,
      'makes_decisions_quickly', 0.08,
      'queue_throughput_discipline', 0.08,
      'attention_to_detail', 0.06,
      'manages_time_effectively', 0.04,
      'receives_coaching', 0.04,
      'positively_influences_team', 0.04
    ),
    'negative_weights', jsonb_build_object(
      'competes_for_recognition', -0.05,
      'has_entrepreneurial_spirit', -0.05,
      'dials_cold_calls', -0.03,
      'prospects_in_community', -0.03,
      'is_fast_start_oriented', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.00,
      'negative_weight_sum', -0.18,
      'model', 'role_fit_v3_2_with_negatives_2026_07_24',
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
    'composure_under_load',       (public.assessment_competency_composure_under_load(ta)      ->> 'adjusted')::numeric,
    'handles_objections',         (public.assessment_competency_handles_objections(ta)        ->> 'adjusted')::numeric,
    'listens_discovers_needs',    (public.assessment_competency_listens_discovers_needs(ta)   ->> 'adjusted')::numeric,
    'retention_watchfulness',     (public.assessment_competency_retention_watchfulness(ta)    ->> 'adjusted')::numeric,
    'presents_solutions',         (public.assessment_competency_presents_solutions(ta)        ->> 'adjusted')::numeric,
    'proactive_touch_discipline', (public.assessment_competency_proactive_touch_discipline(ta)->> 'adjusted')::numeric,
    'handles_rejection',          (public.assessment_competency_handles_rejection(ta)         ->> 'adjusted')::numeric,
    'attention_to_detail',        (public.assessment_competency_attention_to_detail(ta)       ->> 'adjusted')::numeric,
    'makes_decisions_quickly',    (public.assessment_competency_makes_decisions_quickly(ta)   ->> 'adjusted')::numeric,
    'pivots_to_customer_need',    (public.assessment_competency_pivots_to_customer_need(ta)   ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric,
    'competes_for_recognition',   (public.assessment_competency_competes_for_recognition(ta)  ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit', (public.assessment_competency_has_entrepreneurial_spirit(ta)->> 'adjusted')::numeric,
    'prospects_in_community',     (public.assessment_competency_prospects_in_community(ta)    ->> 'adjusted')::numeric
  );

  -- Negatives: escalation is thankless save work with upset customers. Recognition-seekers,
  -- entrepreneurial builders, and community prospectors all want the spotlight or something
  -- they can build — escalation gives them neither.
  fit := (s->>'composure_under_load')::numeric       * 0.20
       + (s->>'handles_objections')::numeric         * 0.15
       + (s->>'listens_discovers_needs')::numeric    * 0.12
       + (s->>'retention_watchfulness')::numeric     * 0.10
       + (s->>'presents_solutions')::numeric         * 0.10
       + (s->>'proactive_touch_discipline')::numeric * 0.08
       + (s->>'handles_rejection')::numeric          * 0.06
       + (s->>'attention_to_detail')::numeric        * 0.05
       + (s->>'makes_decisions_quickly')::numeric    * 0.05
       + (s->>'pivots_to_customer_need')::numeric    * 0.04
       + (s->>'receives_coaching')::numeric          * 0.03
       + (s->>'positively_influences_team')::numeric * 0.02
       + (s->>'competes_for_recognition')::numeric   * (-0.03)
       + (s->>'has_entrepreneurial_spirit')::numeric * (-0.03)
       + (s->>'prospects_in_community')::numeric     * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_escalation',
    'adjusted', s,
    'weights', jsonb_build_object(
      'composure_under_load', 0.20,
      'handles_objections', 0.15,
      'listens_discovers_needs', 0.12,
      'retention_watchfulness', 0.10,
      'presents_solutions', 0.10,
      'proactive_touch_discipline', 0.08,
      'handles_rejection', 0.06,
      'attention_to_detail', 0.05,
      'makes_decisions_quickly', 0.05,
      'pivots_to_customer_need', 0.04,
      'receives_coaching', 0.03,
      'positively_influences_team', 0.02
    ),
    'negative_weights', jsonb_build_object(
      'competes_for_recognition', -0.03,
      'has_entrepreneurial_spirit', -0.03,
      'prospects_in_community', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.00,
      'negative_weight_sum', -0.08,
      'model', 'role_fit_v3_2_with_negatives_2026_07_24',
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
    'attention_to_detail',           (public.assessment_competency_attention_to_detail(ta)            ->> 'adjusted')::numeric,
    'manages_time_effectively',      (public.assessment_competency_manages_time_effectively(ta)       ->> 'adjusted')::numeric,
    'queue_throughput_discipline',   (public.assessment_competency_queue_throughput_discipline(ta)    ->> 'adjusted')::numeric,
    'works_without_close_supervision',(public.assessment_competency_works_without_close_supervision(ta)->> 'adjusted')::numeric,
    'makes_decisions_quickly',       (public.assessment_competency_makes_decisions_quickly(ta)        ->> 'adjusted')::numeric,
    'analytical',                    (public.assessment_competency_analytical(ta)                     ->> 'adjusted')::numeric,
    'receives_coaching',             (public.assessment_competency_receives_coaching(ta)              ->> 'adjusted')::numeric,
    'positively_influences_team',    (public.assessment_competency_positively_influences_team(ta)     ->> 'adjusted')::numeric,
    'cadence_compliance',            (public.assessment_competency_cadence_compliance(ta)             ->> 'adjusted')::numeric,
    'competes_for_recognition',      (public.assessment_competency_competes_for_recognition(ta)       ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit',    (public.assessment_competency_has_entrepreneurial_spirit(ta)     ->> 'adjusted')::numeric,
    'rapid_rapport_warm',            (public.assessment_competency_rapid_rapport_warm(ta)             ->> 'adjusted')::numeric,
    'dials_cold_calls',              (public.assessment_competency_dials_cold_calls(ta)               ->> 'adjusted')::numeric,
    'prospects_in_community',        (public.assessment_competency_prospects_in_community(ta)        ->> 'adjusted')::numeric,
    'is_fast_start_oriented',        (public.assessment_competency_is_fast_start_oriented(ta)         ->> 'adjusted')::numeric
  );

  -- Negatives (biggest set of any role): Support is invisible back-office work. Recognition-
  -- seeking, entrepreneurial ambition, hunter-shape competencies, natural people-charmers,
  -- and fast-start velocity all signal the person will be miserable behind a screen.
  fit := (s->>'attention_to_detail')::numeric            * 0.22
       + (s->>'manages_time_effectively')::numeric       * 0.20
       + (s->>'queue_throughput_discipline')::numeric    * 0.15
       + (s->>'works_without_close_supervision')::numeric* 0.12
       + (s->>'makes_decisions_quickly')::numeric        * 0.08
       + (s->>'analytical')::numeric                     * 0.08
       + (s->>'receives_coaching')::numeric              * 0.06
       + (s->>'positively_influences_team')::numeric     * 0.05
       + (s->>'cadence_compliance')::numeric             * 0.04
       + (s->>'competes_for_recognition')::numeric       * (-0.05)
       + (s->>'has_entrepreneurial_spirit')::numeric     * (-0.05)
       + (s->>'rapid_rapport_warm')::numeric             * (-0.03)
       + (s->>'dials_cold_calls')::numeric               * (-0.03)
       + (s->>'prospects_in_community')::numeric         * (-0.03)
       + (s->>'is_fast_start_oriented')::numeric         * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_support',
    'adjusted', s,
    'weights', jsonb_build_object(
      'attention_to_detail', 0.22,
      'manages_time_effectively', 0.20,
      'queue_throughput_discipline', 0.15,
      'works_without_close_supervision', 0.12,
      'makes_decisions_quickly', 0.08,
      'analytical', 0.08,
      'receives_coaching', 0.06,
      'positively_influences_team', 0.05,
      'cadence_compliance', 0.04
    ),
    'negative_weights', jsonb_build_object(
      'competes_for_recognition', -0.05,
      'has_entrepreneurial_spirit', -0.05,
      'rapid_rapport_warm', -0.03,
      'dials_cold_calls', -0.03,
      'prospects_in_community', -0.03,
      'is_fast_start_oriented', -0.02
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.00,
      'negative_weight_sum', -0.21,
      'model', 'role_fit_v3_2_with_negatives_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;


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
    'has_entrepreneurial_spirit',            (public.assessment_competency_has_entrepreneurial_spirit(ta)            ->> 'adjusted')::numeric,
    'maintains_high_activity',               (public.assessment_competency_maintains_high_activity(ta)               ->> 'adjusted')::numeric,
    'handles_rejection',                     (public.assessment_competency_handles_rejection(ta)                     ->> 'adjusted')::numeric,
    'receives_coaching',                     (public.assessment_competency_receives_coaching(ta)                     ->> 'adjusted')::numeric,
    'works_without_close_supervision',       (public.assessment_competency_works_without_close_supervision(ta)       ->> 'adjusted')::numeric,
    'presents_solutions',                    (public.assessment_competency_presents_solutions(ta)                    ->> 'adjusted')::numeric,
    'handles_objections',                    (public.assessment_competency_handles_objections(ta)                    ->> 'adjusted')::numeric,
    'listens_discovers_needs',               (public.assessment_competency_listens_discovers_needs(ta)               ->> 'adjusted')::numeric,
    'prospects_in_community',                (public.assessment_competency_prospects_in_community(ta)                ->> 'adjusted')::numeric,
    'is_fast_start_oriented',                (public.assessment_competency_is_fast_start_oriented(ta)                ->> 'adjusted')::numeric,
    'dials_cold_calls',                      (public.assessment_competency_dials_cold_calls(ta)                      ->> 'adjusted')::numeric,
    'competes_for_recognition',              (public.assessment_competency_competes_for_recognition(ta)              ->> 'adjusted')::numeric,
    'manages_time_effectively',              (public.assessment_competency_manages_time_effectively(ta)              ->> 'adjusted')::numeric,
    'balances_logic_and_emotion_when_hiring',(public.assessment_competency_balances_logic_and_emotion_when_hiring(ta)->> 'adjusted')::numeric,
    'positively_influences_team',            (public.assessment_competency_positively_influences_team(ta)            ->> 'adjusted')::numeric,
    'attention_to_detail',                   (public.assessment_competency_attention_to_detail(ta)                   ->> 'adjusted')::numeric,
    'queue_throughput_discipline',           (public.assessment_competency_queue_throughput_discipline(ta)           ->> 'adjusted')::numeric
  );

  -- Negatives (light — Aspirant is producer track): service-shape signals mean the person
  -- would be a better fit in a support/queue seat than being groomed to run their own book.
  fit := (s->>'has_entrepreneurial_spirit')::numeric            * 0.14
       + (s->>'maintains_high_activity')::numeric               * 0.12
       + (s->>'handles_rejection')::numeric                     * 0.10
       + (s->>'receives_coaching')::numeric                     * 0.10
       + (s->>'works_without_close_supervision')::numeric       * 0.08
       + (s->>'presents_solutions')::numeric                    * 0.07
       + (s->>'handles_objections')::numeric                    * 0.07
       + (s->>'listens_discovers_needs')::numeric               * 0.06
       + (s->>'prospects_in_community')::numeric                * 0.05
       + (s->>'is_fast_start_oriented')::numeric                * 0.05
       + (s->>'dials_cold_calls')::numeric                      * 0.04
       + (s->>'competes_for_recognition')::numeric              * 0.04
       + (s->>'manages_time_effectively')::numeric              * 0.03
       + (s->>'balances_logic_and_emotion_when_hiring')::numeric* 0.03
       + (s->>'positively_influences_team')::numeric            * 0.02
       + (s->>'attention_to_detail')::numeric                   * (-0.02)
       + (s->>'queue_throughput_discipline')::numeric           * (-0.03);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'aspirant',
    'adjusted', s,
    'weights', jsonb_build_object(
      'has_entrepreneurial_spirit', 0.14,
      'maintains_high_activity', 0.12,
      'handles_rejection', 0.10,
      'receives_coaching', 0.10,
      'works_without_close_supervision', 0.08,
      'presents_solutions', 0.07,
      'handles_objections', 0.07,
      'listens_discovers_needs', 0.06,
      'prospects_in_community', 0.05,
      'is_fast_start_oriented', 0.05,
      'dials_cold_calls', 0.04,
      'competes_for_recognition', 0.04,
      'manages_time_effectively', 0.03,
      'balances_logic_and_emotion_when_hiring', 0.03,
      'positively_influences_team', 0.02
    ),
    'negative_weights', jsonb_build_object(
      'attention_to_detail', -0.02,
      'queue_throughput_discipline', -0.03
    ),
    'meta', jsonb_build_object(
      'positive_weight_sum', 1.00,
      'negative_weight_sum', -0.05,
      'model', 'role_fit_v3_2_with_negatives_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;
