-- Phase 3D atomic rename migration
-- 27 ALTER FUNCTION cts_competency_*_v2 -> canonical + CREATE OR REPLACE of 9 consumers with call sites rewritten
-- Behavior-preserving: cohort md5 of cts_all_competencies output unchanged pre/post.

DO $phase_3d$
DECLARE
  r record;
  transformed_defs jsonb := '{}'::jsonb;
  v_count int;
BEGIN
  -- Step 1: capture current consumer bodies with regex-transformed call sites BEFORE renames
  FOR r IN
    SELECT proname,
           regexp_replace(pg_get_functiondef(oid),
                          'cts_competency_([a-z_]+?)_v2\(',
                          'cts_competency_\1(',
                          'g') AS new_def
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace
      AND proname IN (
        'cts_all_competencies','_hiregauge_get_trait_value',
        'assessment_role_fit_sales_outbound','assessment_role_fit_sales_inbound',
        'assessment_role_fit_sales_in_book','assessment_role_fit_retention_reception',
        'assessment_role_fit_retention_escalation','assessment_role_fit_retention_support',
        'assessment_role_fit_aspirant'
      )
  LOOP
    transformed_defs := transformed_defs || jsonb_build_object(r.proname, r.new_def);
  END LOOP;

  SELECT count(*) INTO v_count FROM jsonb_object_keys(transformed_defs);
  IF v_count <> 9 THEN
    RAISE EXCEPTION 'Phase 3D: expected 9 consumer defs, captured %', v_count;
  END IF;

  -- Step 2: rename 27 competency fns from _v2 to canonical
  ALTER FUNCTION public.cts_competency_analytical_v2(hiring_candidates)                             RENAME TO cts_competency_analytical;
  ALTER FUNCTION public.cts_competency_attention_to_detail_v2(hiring_candidates)                    RENAME TO cts_competency_attention_to_detail;
  ALTER FUNCTION public.cts_competency_balances_logic_and_emotion_when_hiring_v2(hiring_candidates) RENAME TO cts_competency_balances_logic_and_emotion_when_hiring;
  ALTER FUNCTION public.cts_competency_cadence_compliance_v2(hiring_candidates)                     RENAME TO cts_competency_cadence_compliance;
  ALTER FUNCTION public.cts_competency_competes_for_recognition_v2(hiring_candidates)               RENAME TO cts_competency_competes_for_recognition;
  ALTER FUNCTION public.cts_competency_composure_under_load_v2(hiring_candidates)                   RENAME TO cts_competency_composure_under_load;
  ALTER FUNCTION public.cts_competency_cross_sell_instinct_v2(hiring_candidates)                    RENAME TO cts_competency_cross_sell_instinct;
  ALTER FUNCTION public.cts_competency_dials_cold_calls_v2(hiring_candidates)                       RENAME TO cts_competency_dials_cold_calls;
  ALTER FUNCTION public.cts_competency_handles_objections_v2(hiring_candidates)                     RENAME TO cts_competency_handles_objections;
  ALTER FUNCTION public.cts_competency_handles_rejection_v2(hiring_candidates)                      RENAME TO cts_competency_handles_rejection;
  ALTER FUNCTION public.cts_competency_has_entrepreneurial_spirit_v2(hiring_candidates)             RENAME TO cts_competency_has_entrepreneurial_spirit;
  ALTER FUNCTION public.cts_competency_is_fast_start_oriented_v2(hiring_candidates)                 RENAME TO cts_competency_is_fast_start_oriented;
  ALTER FUNCTION public.cts_competency_listens_discovers_needs_v2(hiring_candidates)                RENAME TO cts_competency_listens_discovers_needs;
  ALTER FUNCTION public.cts_competency_maintains_high_activity_v2(hiring_candidates)                RENAME TO cts_competency_maintains_high_activity;
  ALTER FUNCTION public.cts_competency_makes_decisions_quickly_v2(hiring_candidates)                RENAME TO cts_competency_makes_decisions_quickly;
  ALTER FUNCTION public.cts_competency_manages_time_effectively_v2(hiring_candidates)               RENAME TO cts_competency_manages_time_effectively;
  ALTER FUNCTION public.cts_competency_pivots_to_customer_need_v2(hiring_candidates)                RENAME TO cts_competency_pivots_to_customer_need;
  ALTER FUNCTION public.cts_competency_positively_influences_team_v2(hiring_candidates)             RENAME TO cts_competency_positively_influences_team;
  ALTER FUNCTION public.cts_competency_presents_solutions_v2(hiring_candidates)                     RENAME TO cts_competency_presents_solutions;
  ALTER FUNCTION public.cts_competency_proactive_touch_discipline_v2(hiring_candidates)             RENAME TO cts_competency_proactive_touch_discipline;
  ALTER FUNCTION public.cts_competency_prospects_in_community_v2(hiring_candidates)                 RENAME TO cts_competency_prospects_in_community;
  ALTER FUNCTION public.cts_competency_queue_throughput_discipline_v2(hiring_candidates)            RENAME TO cts_competency_queue_throughput_discipline;
  ALTER FUNCTION public.cts_competency_rapid_rapport_warm_v2(hiring_candidates)                     RENAME TO cts_competency_rapid_rapport_warm;
  ALTER FUNCTION public.cts_competency_receives_coaching_v2(hiring_candidates)                      RENAME TO cts_competency_receives_coaching;
  ALTER FUNCTION public.cts_competency_retention_watchfulness_v2(hiring_candidates)                 RENAME TO cts_competency_retention_watchfulness;
  ALTER FUNCTION public.cts_competency_routing_judgment_v2(hiring_candidates)                       RENAME TO cts_competency_routing_judgment;
  ALTER FUNCTION public.cts_competency_works_without_close_supervision_v2(hiring_candidates)        RENAME TO cts_competency_works_without_close_supervision;

  -- Step 3: recreate each consumer with transformed def (call sites now reference canonical names)
  FOR r IN SELECT key, value FROM jsonb_each_text(transformed_defs) LOOP
    EXECUTE r.value;
  END LOOP;
END;
$phase_3d$;
