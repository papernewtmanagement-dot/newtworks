-- HireGauge Phase 3B: additive cutover of two consumers to v2 competency functions.
-- 1) cts_all_competencies: same jsonb output shape, scores now sourced from 27 v2 fns
--    (competency values = v2.adjusted; _lss_deltas values = v2.delta).
-- 2) _hiregauge_get_trait_value: maintains_high_activity branch now uses
--    cts_competency_maintains_high_activity_v2(p_ta).base (preserves pre-LSS semantic).
-- V1 chain (adjusted wrappers + base role fns + 27 v1 competency fns + v4 helpers) untouched.
-- Peter authorized the score-shift diff (session_note 2026-07-24, batches 5+6 handoff).

CREATE OR REPLACE FUNCTION public.cts_all_competencies(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  WITH v AS (
    SELECT
      public.cts_competency_analytical_v2(c.*)                             AS an,
      public.cts_competency_attention_to_detail_v2(c.*)                    AS atd,
      public.cts_competency_balances_logic_and_emotion_when_hiring_v2(c.*) AS bl,
      public.cts_competency_cadence_compliance_v2(c.*)                     AS cc,
      public.cts_competency_competes_for_recognition_v2(c.*)               AS cfr,
      public.cts_competency_composure_under_load_v2(c.*)                   AS cul,
      public.cts_competency_cross_sell_instinct_v2(c.*)                    AS csi,
      public.cts_competency_dials_cold_calls_v2(c.*)                       AS dcc,
      public.cts_competency_handles_objections_v2(c.*)                     AS ho,
      public.cts_competency_handles_rejection_v2(c.*)                      AS hr,
      public.cts_competency_has_entrepreneurial_spirit_v2(c.*)             AS hes,
      public.cts_competency_is_fast_start_oriented_v2(c.*)                 AS ifso,
      public.cts_competency_listens_discovers_needs_v2(c.*)                AS ldn,
      public.cts_competency_maintains_high_activity_v2(c.*)                AS mha,
      public.cts_competency_makes_decisions_quickly_v2(c.*)                AS mdq,
      public.cts_competency_manages_time_effectively_v2(c.*)               AS mte,
      public.cts_competency_pivots_to_customer_need_v2(c.*)                AS ptcn,
      public.cts_competency_positively_influences_team_v2(c.*)             AS pit,
      public.cts_competency_presents_solutions_v2(c.*)                     AS ps,
      public.cts_competency_proactive_touch_discipline_v2(c.*)             AS ptd,
      public.cts_competency_prospects_in_community_v2(c.*)                 AS pic,
      public.cts_competency_queue_throughput_discipline_v2(c.*)            AS qtd,
      public.cts_competency_rapid_rapport_warm_v2(c.*)                     AS rrw,
      public.cts_competency_receives_coaching_v2(c.*)                      AS rc,
      public.cts_competency_retention_watchfulness_v2(c.*)                 AS rw,
      public.cts_competency_routing_judgment_v2(c.*)                       AS rj,
      public.cts_competency_works_without_close_supervision_v2(c.*)        AS wwcs
    FROM public.hiring_candidates c
    WHERE c.id = p_assessment_id
      AND c.deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'sales_outbound', jsonb_build_object(
      'maintains_high_activity',    (mha  ->> 'adjusted')::numeric,
      'handles_rejection',          (hr   ->> 'adjusted')::numeric,
      'prospects_in_community',     (pic  ->> 'adjusted')::numeric,
      'dials_cold_calls',           (dcc  ->> 'adjusted')::numeric,
      'listens_discovers_needs',    (ldn  ->> 'adjusted')::numeric,
      'presents_solutions',         (ps   ->> 'adjusted')::numeric,
      'handles_objections',         (ho   ->> 'adjusted')::numeric,
      'receives_coaching',          (rc   ->> 'adjusted')::numeric,
      'positively_influences_team', (pit  ->> 'adjusted')::numeric
    ),
    'sales_inbound', jsonb_build_object(
      'maintains_high_activity',    (mha  ->> 'adjusted')::numeric,
      'handles_rejection',          (hr   ->> 'adjusted')::numeric,
      'listens_discovers_needs',    (ldn  ->> 'adjusted')::numeric,
      'presents_solutions',         (ps   ->> 'adjusted')::numeric,
      'handles_objections',         (ho   ->> 'adjusted')::numeric,
      'receives_coaching',          (rc   ->> 'adjusted')::numeric,
      'positively_influences_team', (pit  ->> 'adjusted')::numeric,
      'rapid_rapport_warm',         (rrw  ->> 'adjusted')::numeric,
      'cadence_compliance',         (cc   ->> 'adjusted')::numeric
    ),
    'sales_in_book', jsonb_build_object(
      'maintains_high_activity',    (mha  ->> 'adjusted')::numeric,
      'handles_rejection',          (hr   ->> 'adjusted')::numeric,
      'listens_discovers_needs',    (ldn  ->> 'adjusted')::numeric,
      'presents_solutions',         (ps   ->> 'adjusted')::numeric,
      'handles_objections',         (ho   ->> 'adjusted')::numeric,
      'receives_coaching',          (rc   ->> 'adjusted')::numeric,
      'positively_influences_team', (pit  ->> 'adjusted')::numeric,
      'cross_sell_instinct',        (csi  ->> 'adjusted')::numeric,
      'retention_watchfulness',     (rw   ->> 'adjusted')::numeric
    ),
    'retention_reception', jsonb_build_object(
      'listens_discovers_needs',    (ldn  ->> 'adjusted')::numeric,
      'makes_decisions_quickly',    (mdq  ->> 'adjusted')::numeric,
      'receives_coaching',          (rc   ->> 'adjusted')::numeric,
      'positively_influences_team', (pit  ->> 'adjusted')::numeric,
      'rapid_rapport_warm',         (rrw  ->> 'adjusted')::numeric,
      'routing_judgment',           (rj   ->> 'adjusted')::numeric,
      'composure_under_load',       (cul  ->> 'adjusted')::numeric,
      'pivots_to_customer_need',    (ptcn ->> 'adjusted')::numeric
    ),
    'retention_escalation', jsonb_build_object(
      'maintains_high_activity',    (mha  ->> 'adjusted')::numeric,
      'listens_discovers_needs',    (ldn  ->> 'adjusted')::numeric,
      'presents_solutions',         (ps   ->> 'adjusted')::numeric,
      'handles_objections',         (ho   ->> 'adjusted')::numeric,
      'handles_rejection',          (hr   ->> 'adjusted')::numeric,
      'receives_coaching',          (rc   ->> 'adjusted')::numeric,
      'positively_influences_team', (pit  ->> 'adjusted')::numeric,
      'retention_watchfulness',     (rw   ->> 'adjusted')::numeric,
      'proactive_touch_discipline', (ptd  ->> 'adjusted')::numeric,
      'composure_under_load',       (cul  ->> 'adjusted')::numeric
    ),
    'retention_support', jsonb_build_object(
      'manages_time_effectively',        (mte  ->> 'adjusted')::numeric,
      'makes_decisions_quickly',         (mdq  ->> 'adjusted')::numeric,
      'works_without_close_supervision', (wwcs ->> 'adjusted')::numeric,
      'analytical',                      (an   ->> 'adjusted')::numeric,
      'receives_coaching',               (rc   ->> 'adjusted')::numeric,
      'positively_influences_team',      (pit  ->> 'adjusted')::numeric,
      'queue_throughput_discipline',     (qtd  ->> 'adjusted')::numeric,
      'attention_to_detail',             (atd  ->> 'adjusted')::numeric
    ),
    'aspirant', jsonb_build_object(
      'maintains_high_activity',               (mha  ->> 'adjusted')::numeric,
      'handles_rejection',                     (hr   ->> 'adjusted')::numeric,
      'prospects_in_community',                (pic  ->> 'adjusted')::numeric,
      'dials_cold_calls',                      (dcc  ->> 'adjusted')::numeric,
      'listens_discovers_needs',               (ldn  ->> 'adjusted')::numeric,
      'presents_solutions',                    (ps   ->> 'adjusted')::numeric,
      'handles_objections',                    (ho   ->> 'adjusted')::numeric,
      'receives_coaching',                     (rc   ->> 'adjusted')::numeric,
      'positively_influences_team',            (pit  ->> 'adjusted')::numeric,
      'has_entrepreneurial_spirit',            (hes  ->> 'adjusted')::numeric,
      'balances_logic_and_emotion_when_hiring',(bl   ->> 'adjusted')::numeric,
      'is_fast_start_oriented',                (ifso ->> 'adjusted')::numeric,
      'competes_for_recognition',              (cfr  ->> 'adjusted')::numeric
    ),
    '_lss_deltas', jsonb_build_object(
      'sales_outbound', jsonb_build_object(
        'maintains_high_activity',    (mha  ->> 'delta')::numeric,
        'handles_rejection',          (hr   ->> 'delta')::numeric,
        'prospects_in_community',     (pic  ->> 'delta')::numeric,
        'dials_cold_calls',           (dcc  ->> 'delta')::numeric,
        'listens_discovers_needs',    (ldn  ->> 'delta')::numeric,
        'presents_solutions',         (ps   ->> 'delta')::numeric,
        'handles_objections',         (ho   ->> 'delta')::numeric,
        'receives_coaching',          (rc   ->> 'delta')::numeric,
        'positively_influences_team', (pit  ->> 'delta')::numeric
      ),
      'sales_inbound', jsonb_build_object(
        'maintains_high_activity',    (mha  ->> 'delta')::numeric,
        'handles_rejection',          (hr   ->> 'delta')::numeric,
        'listens_discovers_needs',    (ldn  ->> 'delta')::numeric,
        'presents_solutions',         (ps   ->> 'delta')::numeric,
        'handles_objections',         (ho   ->> 'delta')::numeric,
        'receives_coaching',          (rc   ->> 'delta')::numeric,
        'positively_influences_team', (pit  ->> 'delta')::numeric,
        'rapid_rapport_warm',         (rrw  ->> 'delta')::numeric,
        'cadence_compliance',         (cc   ->> 'delta')::numeric
      ),
      'sales_in_book', jsonb_build_object(
        'maintains_high_activity',    (mha  ->> 'delta')::numeric,
        'handles_rejection',          (hr   ->> 'delta')::numeric,
        'listens_discovers_needs',    (ldn  ->> 'delta')::numeric,
        'presents_solutions',         (ps   ->> 'delta')::numeric,
        'handles_objections',         (ho   ->> 'delta')::numeric,
        'receives_coaching',          (rc   ->> 'delta')::numeric,
        'positively_influences_team', (pit  ->> 'delta')::numeric,
        'cross_sell_instinct',        (csi  ->> 'delta')::numeric,
        'retention_watchfulness',     (rw   ->> 'delta')::numeric
      ),
      'retention_reception', jsonb_build_object(
        'listens_discovers_needs',    (ldn  ->> 'delta')::numeric,
        'makes_decisions_quickly',    (mdq  ->> 'delta')::numeric,
        'receives_coaching',          (rc   ->> 'delta')::numeric,
        'positively_influences_team', (pit  ->> 'delta')::numeric,
        'rapid_rapport_warm',         (rrw  ->> 'delta')::numeric,
        'routing_judgment',           (rj   ->> 'delta')::numeric,
        'composure_under_load',       (cul  ->> 'delta')::numeric,
        'pivots_to_customer_need',    (ptcn ->> 'delta')::numeric
      ),
      'retention_escalation', jsonb_build_object(
        'maintains_high_activity',    (mha  ->> 'delta')::numeric,
        'listens_discovers_needs',    (ldn  ->> 'delta')::numeric,
        'presents_solutions',         (ps   ->> 'delta')::numeric,
        'handles_objections',         (ho   ->> 'delta')::numeric,
        'handles_rejection',          (hr   ->> 'delta')::numeric,
        'receives_coaching',          (rc   ->> 'delta')::numeric,
        'positively_influences_team', (pit  ->> 'delta')::numeric,
        'retention_watchfulness',     (rw   ->> 'delta')::numeric,
        'proactive_touch_discipline', (ptd  ->> 'delta')::numeric,
        'composure_under_load',       (cul  ->> 'delta')::numeric
      ),
      'retention_support', jsonb_build_object(
        'manages_time_effectively',        (mte  ->> 'delta')::numeric,
        'makes_decisions_quickly',         (mdq  ->> 'delta')::numeric,
        'works_without_close_supervision', (wwcs ->> 'delta')::numeric,
        'analytical',                      (an   ->> 'delta')::numeric,
        'receives_coaching',               (rc   ->> 'delta')::numeric,
        'positively_influences_team',      (pit  ->> 'delta')::numeric,
        'queue_throughput_discipline',     (qtd  ->> 'delta')::numeric,
        'attention_to_detail',             (atd  ->> 'delta')::numeric
      ),
      'aspirant', jsonb_build_object(
        'maintains_high_activity',               (mha  ->> 'delta')::numeric,
        'handles_rejection',                     (hr   ->> 'delta')::numeric,
        'prospects_in_community',                (pic  ->> 'delta')::numeric,
        'dials_cold_calls',                      (dcc  ->> 'delta')::numeric,
        'listens_discovers_needs',               (ldn  ->> 'delta')::numeric,
        'presents_solutions',                    (ps   ->> 'delta')::numeric,
        'handles_objections',                    (ho   ->> 'delta')::numeric,
        'receives_coaching',                     (rc   ->> 'delta')::numeric,
        'positively_influences_team',            (pit  ->> 'delta')::numeric,
        'has_entrepreneurial_spirit',            (hes  ->> 'delta')::numeric,
        'balances_logic_and_emotion_when_hiring',(bl   ->> 'delta')::numeric,
        'is_fast_start_oriented',                (ifso ->> 'delta')::numeric,
        'competes_for_recognition',              (cfr  ->> 'delta')::numeric
      )
    )
  )
  FROM v;
$function$;


CREATE OR REPLACE FUNCTION public._hiregauge_get_trait_value(p_ta hiring_candidates, p_trait text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_trait
    WHEN 'deadline_motivation'     THEN p_ta.deadline_motivation::numeric
    WHEN 'recognition_drive'       THEN p_ta.recognition_drive::numeric
    WHEN 'assertiveness'           THEN p_ta.assertiveness::numeric
    WHEN 'independent_spirit'      THEN p_ta.independent_spirit::numeric
    WHEN 'analytical'              THEN p_ta.analytical::numeric
    WHEN 'compassion'              THEN p_ta.compassion::numeric
    WHEN 'self_promotion'          THEN p_ta.self_promotion::numeric
    WHEN 'belief_in_others'        THEN p_ta.belief_in_others::numeric
    WHEN 'optimism'                THEN p_ta.optimism::numeric
    WHEN 'overall_score'           THEN p_ta.overall_score::numeric
    WHEN 'lss_total_accuracy'      THEN p_ta.lss_total_accuracy::numeric
    WHEN 'lss_total_ideal_min'     THEN p_ta.lss_total_ideal_min::numeric
    WHEN 'maintains_high_activity' THEN
      (public.cts_competency_maintains_high_activity_v2(p_ta) ->> 'base')::numeric
    ELSE NULL
  END;
$function$;
