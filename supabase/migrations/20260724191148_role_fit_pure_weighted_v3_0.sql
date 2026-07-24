-- Role-fit functions v3.0: pure weighted average of adjusted competency scores.
-- Blind to how the adjusted score was produced (dampeners, LSS math, validity, etc.
-- all live inside assessment_competency_*; role-fit does not re-touch that).
-- No floor caps, no gates, no comp caps, no compound-invalidity checks. Just weights.
-- Output: fit_score 0-100 = SUM(weight * adjusted). weights sum to 1.00 per role.

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
    'handles_rejection',          (public.assessment_competency_handles_rejection(ta)         ->> 'adjusted')::numeric,
    'maintains_high_activity',    (public.assessment_competency_maintains_high_activity(ta)   ->> 'adjusted')::numeric,
    'dials_cold_calls',           (public.assessment_competency_dials_cold_calls(ta)          ->> 'adjusted')::numeric,
    'prospects_in_community',     (public.assessment_competency_prospects_in_community(ta)    ->> 'adjusted')::numeric,
    'handles_objections',         (public.assessment_competency_handles_objections(ta)        ->> 'adjusted')::numeric,
    'presents_solutions',         (public.assessment_competency_presents_solutions(ta)        ->> 'adjusted')::numeric,
    'listens_discovers_needs',    (public.assessment_competency_listens_discovers_needs(ta)   ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric
  );

  -- Weights: cold-outreach role. Rejection tolerance + activity discipline dominate;
  -- conversion competencies mid; team-fit tail.
  fit := (s->>'handles_rejection')::numeric          * 0.20
       + (s->>'maintains_high_activity')::numeric    * 0.16
       + (s->>'dials_cold_calls')::numeric           * 0.13
       + (s->>'prospects_in_community')::numeric     * 0.08
       + (s->>'handles_objections')::numeric         * 0.12
       + (s->>'presents_solutions')::numeric         * 0.10
       + (s->>'listens_discovers_needs')::numeric    * 0.08
       + (s->>'receives_coaching')::numeric          * 0.07
       + (s->>'positively_influences_team')::numeric * 0.06;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_outbound',
    'adjusted', s,
    'weights', jsonb_build_object(
      'handles_rejection', 0.20,
      'maintains_high_activity', 0.16,
      'dials_cold_calls', 0.13,
      'prospects_in_community', 0.08,
      'handles_objections', 0.12,
      'presents_solutions', 0.10,
      'listens_discovers_needs', 0.08,
      'receives_coaching', 0.07,
      'positively_influences_team', 0.06
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'model', 'role_fit_v3_0_pure_weighted_2026_07_24',
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
    'maintains_high_activity',    (public.assessment_competency_maintains_high_activity(ta)   ->> 'adjusted')::numeric,
    'handles_rejection',          (public.assessment_competency_handles_rejection(ta)         ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric
  );

  -- Weights: warm inbound. Rapport on first contact + listening to need dominates;
  -- follow-up cadence matters because not every warm lead closes on first touch;
  -- rejection tolerance minimized (leads self-selected in).
  fit := (s->>'rapid_rapport_warm')::numeric         * 0.20
       + (s->>'listens_discovers_needs')::numeric    * 0.15
       + (s->>'presents_solutions')::numeric         * 0.14
       + (s->>'handles_objections')::numeric         * 0.12
       + (s->>'cadence_compliance')::numeric         * 0.14
       + (s->>'maintains_high_activity')::numeric    * 0.08
       + (s->>'handles_rejection')::numeric          * 0.05
       + (s->>'receives_coaching')::numeric          * 0.06
       + (s->>'positively_influences_team')::numeric * 0.06;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_inbound',
    'adjusted', s,
    'weights', jsonb_build_object(
      'rapid_rapport_warm', 0.20,
      'listens_discovers_needs', 0.15,
      'presents_solutions', 0.14,
      'handles_objections', 0.12,
      'cadence_compliance', 0.14,
      'maintains_high_activity', 0.08,
      'handles_rejection', 0.05,
      'receives_coaching', 0.06,
      'positively_influences_team', 0.06
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'model', 'role_fit_v3_0_pure_weighted_2026_07_24',
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
    'retention_watchfulness',     (public.assessment_competency_retention_watchfulness(ta)    ->> 'adjusted')::numeric,
    'presents_solutions',         (public.assessment_competency_presents_solutions(ta)        ->> 'adjusted')::numeric,
    'handles_objections',         (public.assessment_competency_handles_objections(ta)        ->> 'adjusted')::numeric,
    'maintains_high_activity',    (public.assessment_competency_maintains_high_activity(ta)   ->> 'adjusted')::numeric,
    'handles_rejection',          (public.assessment_competency_handles_rejection(ta)         ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric
  );

  -- Weights: existing-book cross-sell. Cross-sell instinct + hearing opportunity dominate;
  -- book-protection (retention_watchfulness) matters because you're touching your own book;
  -- outbound-flavor competencies minimized.
  fit := (s->>'cross_sell_instinct')::numeric        * 0.22
       + (s->>'listens_discovers_needs')::numeric    * 0.16
       + (s->>'retention_watchfulness')::numeric     * 0.12
       + (s->>'presents_solutions')::numeric         * 0.12
       + (s->>'handles_objections')::numeric         * 0.10
       + (s->>'maintains_high_activity')::numeric    * 0.08
       + (s->>'handles_rejection')::numeric          * 0.06
       + (s->>'receives_coaching')::numeric          * 0.07
       + (s->>'positively_influences_team')::numeric * 0.07;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_in_book',
    'adjusted', s,
    'weights', jsonb_build_object(
      'cross_sell_instinct', 0.22,
      'listens_discovers_needs', 0.16,
      'retention_watchfulness', 0.12,
      'presents_solutions', 0.12,
      'handles_objections', 0.10,
      'maintains_high_activity', 0.08,
      'handles_rejection', 0.06,
      'receives_coaching', 0.07,
      'positively_influences_team', 0.07
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'model', 'role_fit_v3_0_pure_weighted_2026_07_24',
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
    'pivots_to_customer_need',    (public.assessment_competency_pivots_to_customer_need(ta)   ->> 'adjusted')::numeric,
    'routing_judgment',           (public.assessment_competency_routing_judgment(ta)          ->> 'adjusted')::numeric,
    'makes_decisions_quickly',    (public.assessment_competency_makes_decisions_quickly(ta)   ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric
  );

  -- Weights: front-door service. First-touch rapport + listening to need dominate;
  -- composure carries when caller is upset; routing + pivot handle the mechanic;
  -- decisive on the fly beats analysis paralysis.
  fit := (s->>'rapid_rapport_warm')::numeric         * 0.20
       + (s->>'listens_discovers_needs')::numeric    * 0.15
       + (s->>'composure_under_load')::numeric       * 0.14
       + (s->>'pivots_to_customer_need')::numeric    * 0.12
       + (s->>'routing_judgment')::numeric           * 0.13
       + (s->>'makes_decisions_quickly')::numeric    * 0.10
       + (s->>'receives_coaching')::numeric          * 0.08
       + (s->>'positively_influences_team')::numeric * 0.08;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_reception',
    'adjusted', s,
    'weights', jsonb_build_object(
      'rapid_rapport_warm', 0.20,
      'listens_discovers_needs', 0.15,
      'composure_under_load', 0.14,
      'pivots_to_customer_need', 0.12,
      'routing_judgment', 0.13,
      'makes_decisions_quickly', 0.10,
      'receives_coaching', 0.08,
      'positively_influences_team', 0.08
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'model', 'role_fit_v3_0_pure_weighted_2026_07_24',
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
    'proactive_touch_discipline', (public.assessment_competency_proactive_touch_discipline(ta)->> 'adjusted')::numeric,
    'presents_solutions',         (public.assessment_competency_presents_solutions(ta)        ->> 'adjusted')::numeric,
    'handles_rejection',          (public.assessment_competency_handles_rejection(ta)         ->> 'adjusted')::numeric,
    'receives_coaching',          (public.assessment_competency_receives_coaching(ta)         ->> 'adjusted')::numeric,
    'positively_influences_team', (public.assessment_competency_positively_influences_team(ta)->> 'adjusted')::numeric
  );

  -- Weights: upset customers + save conversations + disputes. Composure under load is
  -- the whole game; objection-handling lands the resolution; listen-first proves it's real;
  -- follow-through discipline finishes the save; rejection tolerance still matters because
  -- customer can push back mid-save.
  fit := (s->>'composure_under_load')::numeric       * 0.20
       + (s->>'handles_objections')::numeric         * 0.16
       + (s->>'listens_discovers_needs')::numeric    * 0.12
       + (s->>'retention_watchfulness')::numeric     * 0.12
       + (s->>'proactive_touch_discipline')::numeric * 0.10
       + (s->>'presents_solutions')::numeric         * 0.10
       + (s->>'handles_rejection')::numeric          * 0.08
       + (s->>'receives_coaching')::numeric          * 0.06
       + (s->>'positively_influences_team')::numeric * 0.06;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_escalation',
    'adjusted', s,
    'weights', jsonb_build_object(
      'composure_under_load', 0.20,
      'handles_objections', 0.16,
      'listens_discovers_needs', 0.12,
      'retention_watchfulness', 0.12,
      'proactive_touch_discipline', 0.10,
      'presents_solutions', 0.10,
      'handles_rejection', 0.08,
      'receives_coaching', 0.06,
      'positively_influences_team', 0.06
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'model', 'role_fit_v3_0_pure_weighted_2026_07_24',
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
    'queue_throughput_discipline',   (public.assessment_competency_queue_throughput_discipline(ta)    ->> 'adjusted')::numeric,
    'works_without_close_supervision',(public.assessment_competency_works_without_close_supervision(ta)->> 'adjusted')::numeric,
    'manages_time_effectively',      (public.assessment_competency_manages_time_effectively(ta)       ->> 'adjusted')::numeric,
    'makes_decisions_quickly',       (public.assessment_competency_makes_decisions_quickly(ta)        ->> 'adjusted')::numeric,
    'analytical',                    (public.assessment_competency_analytical(ta)                     ->> 'adjusted')::numeric,
    'receives_coaching',             (public.assessment_competency_receives_coaching(ta)              ->> 'adjusted')::numeric,
    'positively_influences_team',    (public.assessment_competency_positively_influences_team(ta)     ->> 'adjusted')::numeric
  );

  -- Weights: back-office accuracy + throughput. Detail-orientation carries policy accuracy;
  -- throughput discipline moves the queue; self-direction + time management are the shape
  -- of the day; decisive + analytical break ties; team-fit tail.
  fit := (s->>'attention_to_detail')::numeric            * 0.22
       + (s->>'queue_throughput_discipline')::numeric    * 0.18
       + (s->>'works_without_close_supervision')::numeric* 0.14
       + (s->>'manages_time_effectively')::numeric       * 0.14
       + (s->>'makes_decisions_quickly')::numeric        * 0.10
       + (s->>'analytical')::numeric                     * 0.08
       + (s->>'receives_coaching')::numeric              * 0.07
       + (s->>'positively_influences_team')::numeric     * 0.07;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_support',
    'adjusted', s,
    'weights', jsonb_build_object(
      'attention_to_detail', 0.22,
      'queue_throughput_discipline', 0.18,
      'works_without_close_supervision', 0.14,
      'manages_time_effectively', 0.14,
      'makes_decisions_quickly', 0.10,
      'analytical', 0.08,
      'receives_coaching', 0.07,
      'positively_influences_team', 0.07
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'model', 'role_fit_v3_0_pure_weighted_2026_07_24',
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
    'handles_rejection',                     (public.assessment_competency_handles_rejection(ta)                     ->> 'adjusted')::numeric,
    'maintains_high_activity',               (public.assessment_competency_maintains_high_activity(ta)               ->> 'adjusted')::numeric,
    'receives_coaching',                     (public.assessment_competency_receives_coaching(ta)                     ->> 'adjusted')::numeric,
    'presents_solutions',                    (public.assessment_competency_presents_solutions(ta)                    ->> 'adjusted')::numeric,
    'handles_objections',                    (public.assessment_competency_handles_objections(ta)                    ->> 'adjusted')::numeric,
    'listens_discovers_needs',               (public.assessment_competency_listens_discovers_needs(ta)               ->> 'adjusted')::numeric,
    'prospects_in_community',                (public.assessment_competency_prospects_in_community(ta)                ->> 'adjusted')::numeric,
    'is_fast_start_oriented',                (public.assessment_competency_is_fast_start_oriented(ta)                ->> 'adjusted')::numeric,
    'competes_for_recognition',              (public.assessment_competency_competes_for_recognition(ta)              ->> 'adjusted')::numeric,
    'dials_cold_calls',                      (public.assessment_competency_dials_cold_calls(ta)                      ->> 'adjusted')::numeric,
    'balances_logic_and_emotion_when_hiring',(public.assessment_competency_balances_logic_and_emotion_when_hiring(ta)->> 'adjusted')::numeric,
    'positively_influences_team',            (public.assessment_competency_positively_influences_team(ta)            ->> 'adjusted')::numeric
  );

  -- Weights: future-producer track. Entrepreneurial spirit is the defining trait — this is
  -- the seat where they'll run their own book someday. Rejection tolerance + activity
  -- discipline + coaching receptivity are the growth foundation. Full sales stack matters
  -- but no single competency dominates because it's a "become good at all of it" role.
  fit := (s->>'has_entrepreneurial_spirit')::numeric            * 0.15
       + (s->>'handles_rejection')::numeric                     * 0.12
       + (s->>'maintains_high_activity')::numeric               * 0.10
       + (s->>'receives_coaching')::numeric                     * 0.10
       + (s->>'presents_solutions')::numeric                    * 0.08
       + (s->>'handles_objections')::numeric                    * 0.08
       + (s->>'listens_discovers_needs')::numeric               * 0.08
       + (s->>'prospects_in_community')::numeric                * 0.07
       + (s->>'is_fast_start_oriented')::numeric                * 0.06
       + (s->>'competes_for_recognition')::numeric              * 0.05
       + (s->>'dials_cold_calls')::numeric                      * 0.04
       + (s->>'balances_logic_and_emotion_when_hiring')::numeric* 0.04
       + (s->>'positively_influences_team')::numeric            * 0.03;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'aspirant',
    'adjusted', s,
    'weights', jsonb_build_object(
      'has_entrepreneurial_spirit', 0.15,
      'handles_rejection', 0.12,
      'maintains_high_activity', 0.10,
      'receives_coaching', 0.10,
      'presents_solutions', 0.08,
      'handles_objections', 0.08,
      'listens_discovers_needs', 0.08,
      'prospects_in_community', 0.07,
      'is_fast_start_oriented', 0.06,
      'competes_for_recognition', 0.05,
      'dials_cold_calls', 0.04,
      'balances_logic_and_emotion_when_hiring', 0.04,
      'positively_influences_team', 0.03
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'model', 'role_fit_v3_0_pure_weighted_2026_07_24',
      'adjusted_source', 'assessment_competency_* (blind to adjustment mechanism)'
    )
  );
END;
$function$;
