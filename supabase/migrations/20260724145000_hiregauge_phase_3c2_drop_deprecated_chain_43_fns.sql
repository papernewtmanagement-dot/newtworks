-- HireGauge Phase 3C.2: DESTRUCTIVE drop of 43 deprecated functions.
-- Deprecated v1 chain: adjusted wrappers -> base role fns -> v1 competency fns -> v4 helpers.
-- All 9 external consumers rewired to v2 in 3B + 3C.1 (session_note 2026-07-24).
-- Pre-drop audit confirmed zero external callers of these 43 fns (pg_proc, views, edge fns, repo).
-- Drop order: adjusted wrappers -> base role fns -> v1 competency fns -> v4 helpers.
-- Postgres does not track function-to-function dependencies in pg_depend for language sql/plpgsql,
-- so order is strictly cosmetic; each DROP succeeds independently.

-- ROLLBACK PATH: git revert this migration + re-apply original CREATE OR REPLACE blocks from
-- git history (all 43 fns were created by prior migrations in supabase/migrations/).
-- HOWEVER: the correct response to any post-drop issue is to fix v2, not resurrect v1.
-- v1 had known calibration issues (session_note 2026-07-24 references) that v2 corrected.

-- === ORD 1: 7 adjusted wrappers ===
DROP FUNCTION IF EXISTS public.cts_aspirant_competencies_adjusted(p_assessment_id uuid);
DROP FUNCTION IF EXISTS public.cts_retention_escalation_competencies_adjusted(p_assessment_id uuid);
DROP FUNCTION IF EXISTS public.cts_retention_reception_competencies_adjusted(p_assessment_id uuid);
DROP FUNCTION IF EXISTS public.cts_retention_support_competencies_adjusted(p_assessment_id uuid);
DROP FUNCTION IF EXISTS public.cts_sales_in_book_competencies_adjusted(p_assessment_id uuid);
DROP FUNCTION IF EXISTS public.cts_sales_inbound_competencies_adjusted(p_assessment_id uuid);
DROP FUNCTION IF EXISTS public.cts_sales_outbound_competencies_adjusted(p_assessment_id uuid);

-- === ORD 2: 7 base role fns (9-arg positional signature) ===
DROP FUNCTION IF EXISTS public.cts_aspirant_competencies(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_retention_escalation_competencies(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_retention_reception_competencies(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_retention_support_competencies(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_sales_in_book_competencies(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_sales_inbound_competencies(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_sales_outbound_competencies(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);

-- === ORD 3: 27 v1 competency fns (9-arg positional signature) ===
DROP FUNCTION IF EXISTS public.cts_competency_analytical(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_attention_to_detail(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_balances_logic_and_emotion_when_hiring(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_cadence_compliance(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_competes_for_recognition(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_composure_under_load(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_cross_sell_instinct(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_dials_cold_calls(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_handles_objections(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_handles_rejection(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_has_entrepreneurial_spirit(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_is_fast_start_oriented(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_listens_discovers_needs(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_maintains_high_activity(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_makes_decisions_quickly(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_manages_time_effectively(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_pivots_to_customer_need(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_positively_influences_team(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_presents_solutions(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_proactive_touch_discipline(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_prospects_in_community(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_queue_throughput_discipline(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_rapid_rapport_warm(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_receives_coaching(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_retention_watchfulness(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_routing_judgment(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);
DROP FUNCTION IF EXISTS public.cts_competency_works_without_close_supervision(deadline_motivation integer, recognition_drive integer, assertiveness integer, independent_spirit integer, analytical integer, compassion integer, self_promotion integer, belief_in_others integer, optimism integer);

-- === ORD 4: 2 v4 LSS helpers ===
DROP FUNCTION IF EXISTS public._cts_lss_apply_v4(p_base numeric, p_acc_wt numeric, p_spd_wt numeric, p_acc_signal numeric, p_spd_signal numeric, p_rel_factor numeric, p_has_lss boolean);
DROP FUNCTION IF EXISTS public._cts_lss_delta_v4(p_acc_wt numeric, p_spd_wt numeric, p_acc_signal numeric, p_spd_signal numeric, p_has_lss boolean);
