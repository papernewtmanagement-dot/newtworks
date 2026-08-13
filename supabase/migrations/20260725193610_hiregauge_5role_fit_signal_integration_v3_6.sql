-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-25 19:36:10 UTC (ledger name: hiregauge_5role_fit_signal_integration_v3_6) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260725193610.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Sales-Inbound v3.6: linear signals, moderate everywhere
CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_inbound(p_assessment_id uuid)
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
    'analytical',                      (public.assessment_competency_analytical(ta)                      ->> 'adjusted')::numeric,
    'signal_concern',                  (public.assessment_signal_concern(ta)                             ->> 'adjusted')::numeric,
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

  fit := (s->>'rapid_rapport_warm')::numeric              * 0.17
       + (s->>'listens_discovers_needs')::numeric         * 0.13
       + (s->>'presents_solutions')::numeric              * 0.11
       + (s->>'handles_objections')::numeric              * 0.10
       + (s->>'composure_under_load')::numeric            * 0.07
       + (s->>'makes_decisions_quickly')::numeric         * 0.06
       + (s->>'cross_sell_instinct')::numeric             * 0.05
       + (s->>'cadence_compliance')::numeric              * 0.05
       + (s->>'pivots_to_customer_need')::numeric         * 0.04
       + (s->>'receives_coaching')::numeric               * 0.04
       + (s->>'retention_watchfulness')::numeric          * 0.03
       + (s->>'works_without_close_supervision')::numeric * 0.04
       + (s->>'maintains_high_activity')::numeric         * 0.03
       + (s->>'handles_rejection')::numeric               * 0.03
       + (s->>'positively_influences_team')::numeric      * 0.03
       + (s->>'signal_concern')::numeric                  * 0.05
       + (s->>'signal_honesty')::numeric                  * 0.03
       + drive_gated                                       * 0.05
       + hwe_gated                                         * 0.04
       + (s->>'signal_overthinker_penalty')::numeric      * (-0.08)
       + (s->>'dials_cold_calls')::numeric                * (-0.04)
       + (s->>'prospects_in_community')::numeric          * (-0.04)
       + (s->>'has_entrepreneurial_spirit')::numeric      * (-0.03)
       + (s->>'attention_to_detail')::numeric             * (-0.02)
       + (s->>'analytical')::numeric                      * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_inbound',
    'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v3_6_signal_integration_2026_07_25',
      'changes_from_v3_5', 'Added signal_concern 0.05, signal_honesty 0.03, drive_gated 0.05, hwe_gated 0.04, signal_overthinker_penalty -0.08. Trimmed 13 competency positives by 0.17 total to offset.',
      'drive_gated', drive_gated,
      'hwe_gated', hwe_gated
    )
  );
END;
$function$;

-- Sales-In-Book v3.6: LINEAR signals, empathy+honesty central
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
    'prospects_in_community',     (public.assessment_competency_prospects_in_community(ta)     ->> 'adjusted')::numeric,
    'signal_concern',             (public.assessment_signal_concern(ta)                        ->> 'adjusted')::numeric,
    'signal_hwe',                 (public.assessment_signal_hwe(ta)                            ->> 'adjusted')::numeric,
    'signal_drive_engine',        (public.assessment_signal_drive_engine(ta)                   ->> 'adjusted')::numeric,
    'signal_honesty',             (public.assessment_signal_honesty(ta)                        ->> 'adjusted')::numeric,
    'signal_overthinker_penalty', (public.assessment_signal_overthinker_penalty(ta)            ->> 'adjusted')::numeric
  );

  fit := (s->>'cross_sell_instinct')::numeric        * 0.18
       + (s->>'listens_discovers_needs')::numeric    * 0.13
       + (s->>'proactive_touch_discipline')::numeric * 0.11
       + (s->>'retention_watchfulness')::numeric     * 0.09
       + (s->>'presents_solutions')::numeric         * 0.09
       + (s->>'handles_objections')::numeric         * 0.08
       + (s->>'rapid_rapport_warm')::numeric         * 0.06
       + (s->>'cadence_compliance')::numeric         * 0.05
       + (s->>'pivots_to_customer_need')::numeric    * 0.04
       + (s->>'receives_coaching')::numeric          * 0.04
       + (s->>'competes_for_recognition')::numeric   * 0.02
       + (s->>'handles_rejection')::numeric          * 0.02
       + (s->>'positively_influences_team')::numeric * 0.02
       + (s->>'maintains_high_activity')::numeric    * 0.02
       + (s->>'signal_concern')::numeric             * 0.06
       + (s->>'signal_honesty')::numeric             * 0.05
       + (s->>'signal_drive_engine')::numeric        * 0.03
       + (s->>'signal_hwe')::numeric                 * 0.03
       + (s->>'signal_overthinker_penalty')::numeric * (-0.05)
       + (s->>'dials_cold_calls')::numeric           * (-0.03)
       + (s->>'has_entrepreneurial_spirit')::numeric * (-0.03)
       + (s->>'is_fast_start_oriented')::numeric     * (-0.03)
       + (s->>'prospects_in_community')::numeric     * (-0.03);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_in_book',
    'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v3_6_signal_integration_2026_07_25',
      'changes_from_v3_5', 'Added signal_concern 0.06, signal_honesty 0.05, signal_drive_engine 0.03 LINEAR, signal_hwe 0.03 LINEAR, signal_overthinker_penalty -0.05. Trimmed 14 competency positives by 0.17 total to offset.'
    )
  );
END;
$function$;

-- Retention-Reception v3.5: gated drive+hwe (activity/pace), concern+honesty, hardened overthinker
CREATE OR REPLACE FUNCTION public.assessment_role_fit_retention_reception(p_assessment_id uuid)
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
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_reception');
  END IF;

  s := jsonb_build_object(
    'rapid_rapport_warm',          (public.assessment_competency_rapid_rapport_warm(ta)          ->> 'adjusted')::numeric,
    'listens_discovers_needs',     (public.assessment_competency_listens_discovers_needs(ta)     ->> 'adjusted')::numeric,
    'composure_under_load',        (public.assessment_competency_composure_under_load(ta)        ->> 'adjusted')::numeric,
    'routing_judgment',            (public.assessment_competency_routing_judgment(ta)            ->> 'adjusted')::numeric,
    'pivots_to_customer_need',     (public.assessment_competency_pivots_to_customer_need(ta)     ->> 'adjusted')::numeric,
    'handles_objections',          (public.assessment_competency_handles_objections(ta)          ->> 'adjusted')::numeric,
    'queue_throughput_discipline', (public.assessment_competency_queue_throughput_discipline(ta) ->> 'adjusted')::numeric,
    'makes_decisions_quickly',     (public.assessment_competency_makes_decisions_quickly(ta)     ->> 'adjusted')::numeric,
    'attention_to_detail',         (public.assessment_competency_attention_to_detail(ta)         ->> 'adjusted')::numeric,
    'retention_watchfulness',      (public.assessment_competency_retention_watchfulness(ta)      ->> 'adjusted')::numeric,
    'manages_time_effectively',    (public.assessment_competency_manages_time_effectively(ta)    ->> 'adjusted')::numeric,
    'receives_coaching',           (public.assessment_competency_receives_coaching(ta)           ->> 'adjusted')::numeric,
    'cadence_compliance',          (public.assessment_competency_cadence_compliance(ta)          ->> 'adjusted')::numeric,
    'positively_influences_team',  (public.assessment_competency_positively_influences_team(ta)  ->> 'adjusted')::numeric,
    'competes_for_recognition',    (public.assessment_competency_competes_for_recognition(ta)    ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit',  (public.assessment_competency_has_entrepreneurial_spirit(ta)  ->> 'adjusted')::numeric,
    'dials_cold_calls',            (public.assessment_competency_dials_cold_calls(ta)            ->> 'adjusted')::numeric,
    'prospects_in_community',      (public.assessment_competency_prospects_in_community(ta)      ->> 'adjusted')::numeric,
    'is_fast_start_oriented',      (public.assessment_competency_is_fast_start_oriented(ta)      ->> 'adjusted')::numeric,
    'signal_concern',              (public.assessment_signal_concern(ta)                         ->> 'adjusted')::numeric,
    'signal_hwe',                  (public.assessment_signal_hwe(ta)                             ->> 'adjusted')::numeric,
    'signal_drive_engine',         (public.assessment_signal_drive_engine(ta)                    ->> 'adjusted')::numeric,
    'signal_honesty',              (public.assessment_signal_honesty(ta)                         ->> 'adjusted')::numeric,
    'signal_overthinker_penalty',  (public.assessment_signal_overthinker_penalty(ta)             ->> 'adjusted')::numeric
  );

  drive_gated := CASE
    WHEN (s->>'signal_drive_engine')::numeric < 50 THEN 0
    WHEN (s->>'signal_drive_engine')::numeric > 70 THEN (s->>'signal_drive_engine')::numeric
    ELSE ((s->>'signal_drive_engine')::numeric - 50) * ((s->>'signal_drive_engine')::numeric / 20.0)
  END;
  hwe_gated := GREATEST(0, (s->>'signal_hwe')::numeric - 55) * 100.0 / 45.0;

  fit := (s->>'rapid_rapport_warm')::numeric          * 0.15
       + (s->>'listens_discovers_needs')::numeric     * 0.13
       + (s->>'composure_under_load')::numeric        * 0.10
       + (s->>'routing_judgment')::numeric            * 0.10
       + (s->>'pivots_to_customer_need')::numeric     * 0.09
       + (s->>'handles_objections')::numeric          * 0.07
       + (s->>'queue_throughput_discipline')::numeric * 0.07
       + (s->>'makes_decisions_quickly')::numeric     * 0.06
       + (s->>'attention_to_detail')::numeric         * 0.05
       + (s->>'retention_watchfulness')::numeric      * 0.04
       + (s->>'manages_time_effectively')::numeric    * 0.04
       + (s->>'receives_coaching')::numeric           * 0.04
       + (s->>'cadence_compliance')::numeric          * 0.03
       + (s->>'positively_influences_team')::numeric  * 0.04
       + (s->>'signal_concern')::numeric              * 0.05
       + (s->>'signal_honesty')::numeric              * 0.03
       + drive_gated                                   * 0.04
       + hwe_gated                                     * 0.05
       + (s->>'signal_overthinker_penalty')::numeric  * (-0.08)
       + (s->>'competes_for_recognition')::numeric    * (-0.05)
       + (s->>'has_entrepreneurial_spirit')::numeric  * (-0.05)
       + (s->>'dials_cold_calls')::numeric            * (-0.03)
       + (s->>'prospects_in_community')::numeric      * (-0.03)
       + (s->>'is_fast_start_oriented')::numeric      * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_reception',
    'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v3_5_signal_integration_2026_07_25',
      'changes_from_v3_4', 'Added signal_concern 0.05, signal_honesty 0.03, drive_gated 0.04, hwe_gated 0.05, signal_overthinker_penalty -0.08. Trimmed 13 competency positives by 0.17 total to offset.',
      'drive_gated', drive_gated,
      'hwe_gated', hwe_gated
    )
  );
END;
$function$;

-- Retention-Escalation v3.6: LINEAR signals, concern+honesty STRONG, overthinker LIGHT negative
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
    'is_fast_start_oriented',     (public.assessment_competency_is_fast_start_oriented(ta)     ->> 'adjusted')::numeric,
    'signal_concern',             (public.assessment_signal_concern(ta)                        ->> 'adjusted')::numeric,
    'signal_hwe',                 (public.assessment_signal_hwe(ta)                            ->> 'adjusted')::numeric,
    'signal_drive_engine',        (public.assessment_signal_drive_engine(ta)                   ->> 'adjusted')::numeric,
    'signal_honesty',             (public.assessment_signal_honesty(ta)                        ->> 'adjusted')::numeric,
    'signal_overthinker_penalty', (public.assessment_signal_overthinker_penalty(ta)            ->> 'adjusted')::numeric
  );

  fit := (s->>'composure_under_load')::numeric       * 0.17
       + (s->>'handles_objections')::numeric         * 0.12
       + (s->>'listens_discovers_needs')::numeric    * 0.09
       + (s->>'retention_watchfulness')::numeric     * 0.09
       + (s->>'presents_solutions')::numeric         * 0.09
       + (s->>'proactive_touch_discipline')::numeric * 0.07
       + (s->>'rapid_rapport_warm')::numeric         * 0.06
       + (s->>'handles_rejection')::numeric          * 0.05
       + (s->>'analytical')::numeric                 * 0.05
       + (s->>'attention_to_detail')::numeric        * 0.03
       + (s->>'makes_decisions_quickly')::numeric    * 0.03
       + (s->>'pivots_to_customer_need')::numeric    * 0.03
       + (s->>'routing_judgment')::numeric           * 0.02
       + (s->>'receives_coaching')::numeric          * 0.01
       + (s->>'positively_influences_team')::numeric * 0.01
       + (s->>'signal_concern')::numeric             * 0.06
       + (s->>'signal_honesty')::numeric             * 0.05
       + (s->>'signal_drive_engine')::numeric        * 0.03
       + (s->>'signal_hwe')::numeric                 * 0.03
       + (s->>'signal_overthinker_penalty')::numeric * (-0.02)
       + (s->>'competes_for_recognition')::numeric   * (-0.03)
       + (s->>'has_entrepreneurial_spirit')::numeric * (-0.03)
       + (s->>'prospects_in_community')::numeric     * (-0.02)
       + (s->>'dials_cold_calls')::numeric           * (-0.02)
       + (s->>'is_fast_start_oriented')::numeric     * (-0.02);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'retention_escalation',
    'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v3_6_signal_integration_2026_07_25',
      'changes_from_v3_5', 'Added signal_concern 0.06, signal_honesty 0.05, signal_drive_engine 0.03 LINEAR, signal_hwe 0.03 LINEAR, signal_overthinker_penalty -0.02 (light — deliberation is a feature for defusion). Trimmed 15 competency positives by 0.17 total to offset. RE concern kept moderate 0.06 (not 0.08) to preserve Anthony SO argmax over RE (his concern=89).'
    )
  );
END;
$function$;

-- Aspirant v3.6: gated drive+hwe STRONG (owner durability), honesty STRONG, moderate concern, overthinker moderate negative
CREATE OR REPLACE FUNCTION public.assessment_role_fit_aspirant(p_assessment_id uuid)
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
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'aspirant');
  END IF;

  s := jsonb_build_object(
    'has_entrepreneurial_spirit',             (public.assessment_competency_has_entrepreneurial_spirit(ta)             ->> 'adjusted')::numeric,
    'maintains_high_activity',                (public.assessment_competency_maintains_high_activity(ta)                ->> 'adjusted')::numeric,
    'handles_rejection',                      (public.assessment_competency_handles_rejection(ta)                      ->> 'adjusted')::numeric,
    'receives_coaching',                      (public.assessment_competency_receives_coaching(ta)                      ->> 'adjusted')::numeric,
    'composure_under_load',                   (public.assessment_competency_composure_under_load(ta)                   ->> 'adjusted')::numeric,
    'works_without_close_supervision',        (public.assessment_competency_works_without_close_supervision(ta)        ->> 'adjusted')::numeric,
    'competes_for_recognition',               (public.assessment_competency_competes_for_recognition(ta)               ->> 'adjusted')::numeric,
    'makes_decisions_quickly',                (public.assessment_competency_makes_decisions_quickly(ta)                ->> 'adjusted')::numeric,
    'balances_logic_and_emotion_when_hiring', (public.assessment_competency_balances_logic_and_emotion_when_hiring(ta) ->> 'adjusted')::numeric,
    'attention_to_detail',                    (public.assessment_competency_attention_to_detail(ta)                    ->> 'adjusted')::numeric,
    'rapid_rapport_warm',                     (public.assessment_competency_rapid_rapport_warm(ta)                     ->> 'adjusted')::numeric,
    'handles_objections',                     (public.assessment_competency_handles_objections(ta)                     ->> 'adjusted')::numeric,
    'presents_solutions',                     (public.assessment_competency_presents_solutions(ta)                     ->> 'adjusted')::numeric,
    'pivots_to_customer_need',                (public.assessment_competency_pivots_to_customer_need(ta)                ->> 'adjusted')::numeric,
    'cadence_compliance',                     (public.assessment_competency_cadence_compliance(ta)                     ->> 'adjusted')::numeric,
    'analytical',                             (public.assessment_competency_analytical(ta)                             ->> 'adjusted')::numeric,
    'cross_sell_instinct',                    (public.assessment_competency_cross_sell_instinct(ta)                    ->> 'adjusted')::numeric,
    'proactive_touch_discipline',             (public.assessment_competency_proactive_touch_discipline(ta)             ->> 'adjusted')::numeric,
    'listens_discovers_needs',                (public.assessment_competency_listens_discovers_needs(ta)                ->> 'adjusted')::numeric,
    'manages_time_effectively',               (public.assessment_competency_manages_time_effectively(ta)               ->> 'adjusted')::numeric,
    'positively_influences_team',             (public.assessment_competency_positively_influences_team(ta)             ->> 'adjusted')::numeric,
    'retention_watchfulness',                 (public.assessment_competency_retention_watchfulness(ta)                 ->> 'adjusted')::numeric,
    'is_fast_start_oriented',                 (public.assessment_competency_is_fast_start_oriented(ta)                 ->> 'adjusted')::numeric,
    'prospects_in_community',                 (public.assessment_competency_prospects_in_community(ta)                 ->> 'adjusted')::numeric,
    'dials_cold_calls',                       (public.assessment_competency_dials_cold_calls(ta)                       ->> 'adjusted')::numeric,
    'queue_throughput_discipline',            (public.assessment_competency_queue_throughput_discipline(ta)            ->> 'adjusted')::numeric,
    'signal_concern',                         (public.assessment_signal_concern(ta)                                    ->> 'adjusted')::numeric,
    'signal_hwe',                             (public.assessment_signal_hwe(ta)                                        ->> 'adjusted')::numeric,
    'signal_drive_engine',                    (public.assessment_signal_drive_engine(ta)                               ->> 'adjusted')::numeric,
    'signal_honesty',                         (public.assessment_signal_honesty(ta)                                    ->> 'adjusted')::numeric,
    'signal_overthinker_penalty',             (public.assessment_signal_overthinker_penalty(ta)                        ->> 'adjusted')::numeric
  );

  drive_gated := CASE
    WHEN (s->>'signal_drive_engine')::numeric < 50 THEN 0
    WHEN (s->>'signal_drive_engine')::numeric > 70 THEN (s->>'signal_drive_engine')::numeric
    ELSE ((s->>'signal_drive_engine')::numeric - 50) * ((s->>'signal_drive_engine')::numeric / 20.0)
  END;
  hwe_gated := GREATEST(0, (s->>'signal_hwe')::numeric - 55) * 100.0 / 45.0;

  fit := (s->>'has_entrepreneurial_spirit')::numeric              * 0.07
       + (s->>'maintains_high_activity')::numeric                 * 0.06
       + (s->>'handles_rejection')::numeric                       * 0.06
       + (s->>'receives_coaching')::numeric                       * 0.06
       + (s->>'composure_under_load')::numeric                    * 0.05
       + (s->>'works_without_close_supervision')::numeric         * 0.05
       + (s->>'competes_for_recognition')::numeric                * 0.05
       + (s->>'makes_decisions_quickly')::numeric                 * 0.04
       + (s->>'balances_logic_and_emotion_when_hiring')::numeric  * 0.03
       + (s->>'attention_to_detail')::numeric                     * 0.03
       + (s->>'rapid_rapport_warm')::numeric                      * 0.03
       + (s->>'handles_objections')::numeric                      * 0.03
       + (s->>'presents_solutions')::numeric                      * 0.03
       + (s->>'pivots_to_customer_need')::numeric                 * 0.03
       + (s->>'cadence_compliance')::numeric                      * 0.02
       + (s->>'analytical')::numeric                              * 0.02
       + (s->>'cross_sell_instinct')::numeric                     * 0.02
       + (s->>'proactive_touch_discipline')::numeric              * 0.02
       + (s->>'listens_discovers_needs')::numeric                 * 0.03
       + (s->>'manages_time_effectively')::numeric                * 0.02
       + (s->>'positively_influences_team')::numeric              * 0.02
       + (s->>'retention_watchfulness')::numeric                  * 0.02
       + (s->>'is_fast_start_oriented')::numeric                  * 0.02
       + (s->>'prospects_in_community')::numeric                  * 0.02
       + (s->>'dials_cold_calls')::numeric                        * 0.02
       + (s->>'signal_honesty')::numeric                          * 0.05
       + (s->>'signal_concern')::numeric                          * 0.03
       + drive_gated                                               * 0.06
       + hwe_gated                                                 * 0.05
       + (s->>'signal_overthinker_penalty')::numeric              * (-0.10)
       + (s->>'queue_throughput_discipline')::numeric             * (-0.05);

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'aspirant',
    'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v3_6_signal_integration_2026_07_25',
      'changes_from_v3_5', 'Added signal_honesty 0.05 LINEAR, signal_concern 0.03 LINEAR, drive_gated 0.06 (gated 50-70 ramp), hwe_gated 0.05 (55-100 rescale), signal_overthinker_penalty -0.10. Trimmed 18 competency positives by 0.19 total to offset.',
      'drive_gated', drive_gated,
      'hwe_gated', hwe_gated
    )
  );
END;
$function$;
