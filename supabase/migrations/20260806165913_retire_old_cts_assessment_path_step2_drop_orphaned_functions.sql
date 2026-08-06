-- Step 2: drop functions that were EXCLUSIVELY reachable through the old CTS
-- path (confirmed via caller-graph check: only called by assessment_role_fit_*
-- / assessment_best_fit_role's now-removed v1 branch / each other; fully
-- superseded by the newtworks_* v2 equivalents).

DROP FUNCTION IF EXISTS public.assessment_role_fit_aspirant(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_retention_escalation(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_retention_reception(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_retention_support(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_sales_in_book(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_sales_inbound(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_sales_outbound(uuid);

DROP FUNCTION IF EXISTS public.assessment_all_competencies(uuid);

DROP FUNCTION IF EXISTS public.assessment_competency_analytical(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_attention_to_detail(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_balances_logic_and_emotion_when_hiring(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_cadence_compliance(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_competes_for_recognition(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_composure_under_load(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_cross_sell_instinct(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_dials_cold_calls(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_handles_objections(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_handles_rejection(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_has_entrepreneurial_spirit(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_is_fast_start_oriented(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_listens_discovers_needs(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_maintains_high_activity(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_makes_decisions_quickly(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_manages_time_effectively(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_pivots_to_customer_need(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_positively_influences_team(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_presents_solutions(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_proactive_touch_discipline(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_prospects_in_community(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_queue_throughput_discipline(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_rapid_rapport_warm(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_receives_coaching(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_retention_watchfulness(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_routing_judgment(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_competency_works_without_close_supervision(hiring_candidates);

DROP FUNCTION IF EXISTS public.assessment_signal_concern(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_signal_honesty(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_signal_hwe(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_signal_drive_engine(hiring_candidates);
DROP FUNCTION IF EXISTS public.assessment_signal_overthinker_penalty(hiring_candidates);

DROP FUNCTION IF EXISTS public._assessment_role_fit_apply_gates(uuid, text, numeric, numeric, text, numeric);
DROP FUNCTION IF EXISTS public._assessment_role_fit_contrib(numeric, numeric, boolean);
DROP FUNCTION IF EXISTS public._assessment_role_fit_gates(uuid);
DROP FUNCTION IF EXISTS public._assessment_apply_reliability_confidence(integer, text);
DROP FUNCTION IF EXISTS public._assessment_distortion_severity(text);
