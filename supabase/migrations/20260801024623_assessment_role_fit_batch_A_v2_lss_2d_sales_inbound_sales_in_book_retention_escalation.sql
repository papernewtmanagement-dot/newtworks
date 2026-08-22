-- Step 5 batch A (fns 2-4 of 7): sales_inbound, sales_in_book, retention_escalation
-- All three get LSS 2d role-fit curve applied to their weighted-competency fit.
-- Range map per hiregauge_role_ideal_ranges:
--   sales_inbound        55 / 90
--   sales_in_book        58 / 92
--   retention_escalation 62 / 90

-- ============================================================
-- fn #2: assessment_role_fit_sales_inbound
-- ============================================================
CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_inbound(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  s jsonb;
  fit numeric;
  fit_base numeric;
  v_lss jsonb;
  v_composite numeric;
  v_floor numeric;
  v_ceiling numeric;
  v_floor_mult numeric;
  v_ceiling_mult numeric;
  v_lss_mult numeric;
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
    'competes_for_recognition',        (public.assessment_competency_competes_for_recognition(ta)        ->> 'adjusted')::numeric,
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
       + (s->>'competes_for_recognition')::numeric        * 0.02
       + (s->>'dials_cold_calls')::numeric                * (-0.04)
       + (s->>'prospects_in_community')::numeric          * (-0.04)
       + (s->>'has_entrepreneurial_spirit')::numeric      * (-0.03)
       + (s->>'attention_to_detail')::numeric             * (-0.02)
       + (s->>'analytical')::numeric                      * (-0.02);

  fit_base := fit;
  v_lss := public.hiregauge_lss_delta_v2(ta);
  v_composite := (v_lss->>'intelligence_composite')::numeric;
  SELECT intelligence_ideal_min, intelligence_ideal_max
    INTO v_floor, v_ceiling
    FROM public.hiregauge_role_ideal_ranges
    WHERE agency_id = ta.agency_id
      AND role_category = 'sales_inbound'
      AND role_level = 'default';
  v_floor_mult   := public.hiregauge_lss_penalty_v2(v_composite, v_floor);
  v_ceiling_mult := public.hiregauge_lss_ceiling_penalty_v2(v_composite, v_ceiling);
  v_lss_mult     := v_floor_mult * v_ceiling_mult;
  fit := fit_base * v_lss_mult;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int, 'role', 'sales_inbound', 'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v4_0_lss_2d_2026_08_01',
      'changes_from_v3_6b', 'Added LSS 2d role-fit curve (floor 55, ceiling 90) via hiregauge_lss_penalty_v2 + hiregauge_lss_ceiling_penalty_v2 helpers. Compounds with per-competency 2c penalty. Base weights unchanged.',
      'fit_base_pre_lss', ROUND(fit_base, 2),
      'lss_composite', v_composite,
      'lss_floor', v_floor,
      'lss_ceiling', v_ceiling,
      'lss_floor_mult', ROUND(v_floor_mult, 4),
      'lss_ceiling_mult', ROUND(v_ceiling_mult, 4),
      'lss_total_mult', ROUND(v_lss_mult, 4)
    )
  );
END;
$function$;

-- ============================================================
-- fn #3: assessment_role_fit_sales_in_book
-- ============================================================
CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_in_book(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  s jsonb;
  fit numeric;
  fit_base numeric;
  v_lss jsonb;
  v_composite numeric;
  v_floor numeric;
  v_ceiling numeric;
  v_floor_mult numeric;
  v_ceiling_mult numeric;
  v_lss_mult numeric;
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

  fit_base := fit;
  v_lss := public.hiregauge_lss_delta_v2(ta);
  v_composite := (v_lss->>'intelligence_composite')::numeric;
  SELECT intelligence_ideal_min, intelligence_ideal_max
    INTO v_floor, v_ceiling
    FROM public.hiregauge_role_ideal_ranges
    WHERE agency_id = ta.agency_id
      AND role_category = 'sales_in_book'
      AND role_level = 'default';
  v_floor_mult   := public.hiregauge_lss_penalty_v2(v_composite, v_floor);
  v_ceiling_mult := public.hiregauge_lss_ceiling_penalty_v2(v_composite, v_ceiling);
  v_lss_mult     := v_floor_mult * v_ceiling_mult;
  fit := fit_base * v_lss_mult;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int, 'role', 'sales_in_book', 'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v4_0_lss_2d_2026_08_01',
      'changes_from_v3_5', 'Added LSS 2d role-fit curve (floor 58, ceiling 92) via hiregauge_lss_penalty_v2 + hiregauge_lss_ceiling_penalty_v2 helpers. Compounds with per-competency 2c penalty. Base weights unchanged.',
      'fit_base_pre_lss', ROUND(fit_base, 2),
      'lss_composite', v_composite,
      'lss_floor', v_floor,
      'lss_ceiling', v_ceiling,
      'lss_floor_mult', ROUND(v_floor_mult, 4),
      'lss_ceiling_mult', ROUND(v_ceiling_mult, 4),
      'lss_total_mult', ROUND(v_lss_mult, 4)
    )
  );
END;
$function$;

-- ============================================================
-- fn #4: assessment_role_fit_retention_escalation
-- ============================================================
CREATE OR REPLACE FUNCTION public.assessment_role_fit_retention_escalation(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  s jsonb;
  fit numeric;
  fit_base numeric;
  v_lss jsonb;
  v_composite numeric;
  v_floor numeric;
  v_ceiling numeric;
  v_floor_mult numeric;
  v_ceiling_mult numeric;
  v_lss_mult numeric;
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

  fit_base := fit;
  v_lss := public.hiregauge_lss_delta_v2(ta);
  v_composite := (v_lss->>'intelligence_composite')::numeric;
  SELECT intelligence_ideal_min, intelligence_ideal_max
    INTO v_floor, v_ceiling
    FROM public.hiregauge_role_ideal_ranges
    WHERE agency_id = ta.agency_id
      AND role_category = 'retention_escalation'
      AND role_level = 'default';
  v_floor_mult   := public.hiregauge_lss_penalty_v2(v_composite, v_floor);
  v_ceiling_mult := public.hiregauge_lss_ceiling_penalty_v2(v_composite, v_ceiling);
  v_lss_mult     := v_floor_mult * v_ceiling_mult;
  fit := fit_base * v_lss_mult;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int, 'role', 'retention_escalation', 'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v4_0_lss_2d_2026_08_01',
      'changes_from_v3_5', 'Added LSS 2d role-fit curve (floor 62, ceiling 90) via hiregauge_lss_penalty_v2 + hiregauge_lss_ceiling_penalty_v2 helpers. Compounds with per-competency 2c penalty. Base weights unchanged.',
      'fit_base_pre_lss', ROUND(fit_base, 2),
      'lss_composite', v_composite,
      'lss_floor', v_floor,
      'lss_ceiling', v_ceiling,
      'lss_floor_mult', ROUND(v_floor_mult, 4),
      'lss_ceiling_mult', ROUND(v_ceiling_mult, 4),
      'lss_total_mult', ROUND(v_lss_mult, 4)
    )
  );
END;
$function$;
