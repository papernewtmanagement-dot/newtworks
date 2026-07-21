-- Migration 20260721003058 (mirror of applied migration)
-- HireGauge LSS per-competency weighting sprint — Step 3, continuation
-- Rewrites 3 retention fns + aspirant fn (v4 asymmetric, per-competency weighted)

-- ============================================================================
-- 5. RETENTION RECEPTION (8 competencies)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cts_retention_reception_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH adj AS (
    SELECT
      deadline_motivation AS dm, recognition_drive AS rd, assertiveness AS ass,
      independent_spirit AS is_val, analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      (lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL AND lss_problem_solving_accuracy IS NOT NULL
       AND lss_math_speed_seconds IS NOT NULL AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL) AS has_lss,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END)-1.5)/1.5 AS acc_signal,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END)-1.5)/1.5 AS spd_signal,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END))::int AS acc_flags_int,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END))::int AS spd_flags_int,
      public._cts_reliability_confidence(reliability) AS rel_factor,
      public._cts_distortion_severity(response_distortion) AS dist_sev,
      reliability AS rel, response_distortion AS dist,
      (SELECT jsonb_object_agg(competency, jsonb_build_object('a', lss_acc_weight, 's', lss_spd_weight))
       FROM public.hiregauge_competencies) AS w
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'listens_discovers_needs', public._cts_lss_apply_v4(
      (14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op,
      (w->'listens_discovers_needs'->>'a')::numeric, (w->'listens_discovers_needs'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'makes_decisions_quickly', public._cts_lss_apply_v4(
      (28.788259) + (0.144387)*dm + (0.001618)*rd + (0.140225)*ass + (0.137139)*is_val + (-0.143650)*an + (-0.146024)*com + (0.147148)*sp + (-0.001939)*bo + (0.138712)*op,
      (w->'makes_decisions_quickly'->>'a')::numeric, (w->'makes_decisions_quickly'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'receives_coaching', public._cts_lss_apply_v4(
      (33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op,
      (w->'receives_coaching'->>'a')::numeric, (w->'receives_coaching'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'positively_influences_team', public._cts_lss_apply_v4(
      op::numeric,
      (w->'positively_influences_team'->>'a')::numeric, (w->'positively_influences_team'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'rapid_rapport_warm', public._cts_lss_apply_v4(
      (20.000000) + (0.300000)*com + (0.200000)*op + (0.200000)*bo + (-0.050000)*an + (0.050000)*ass,
      (w->'rapid_rapport_warm'->>'a')::numeric, (w->'rapid_rapport_warm'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'routing_judgment', public._cts_lss_apply_v4(
      (22.000000) + (0.250000)*an + (0.200000)*bo + (0.150000)*com + (0.050000)*dm + (0.050000)*op + (0.050000)*ass + (-0.050000)*is_val + (-0.050000)*sp,
      (w->'routing_judgment'->>'a')::numeric, (w->'routing_judgment'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'composure_under_load', public._cts_lss_apply_v4(
      (18.000000) + (0.250000)*op + (0.200000)*com + (0.100000)*ass + (0.050000)*is_val + (0.050000)*dm + (0.050000)*bo + (-0.050000)*an,
      (w->'composure_under_load'->>'a')::numeric, (w->'composure_under_load'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'pivots_to_customer_need', public._cts_lss_apply_v4(
      (12.000000) + (0.250000)*com + (0.200000)*an + (0.150000)*ass + (0.100000)*op + (0.100000)*bo + (0.050000)*rd,
      (w->'pivots_to_customer_need'->>'a')::numeric, (w->'pivots_to_customer_need'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    '_meta', jsonb_build_object(
      'has_lss', has_lss, 'acc_flags', acc_flags_int, 'spd_flags', spd_flags_int,
      'reliability', rel, 'distortion', dist,
      'reliability_factor', rel_factor, 'distortion_severity', dist_sev,
      'role', 'retention_reception', 'model', 'sensitivity_weighted_v4_asymmetric'
    )
  )
  FROM adj;
$function$;


-- ============================================================================
-- 6. RETENTION ESCALATION (8 competencies)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cts_retention_escalation_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH adj AS (
    SELECT
      deadline_motivation AS dm, recognition_drive AS rd, assertiveness AS ass,
      independent_spirit AS is_val, analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      (lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL AND lss_problem_solving_accuracy IS NOT NULL
       AND lss_math_speed_seconds IS NOT NULL AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL) AS has_lss,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END)-1.5)/1.5 AS acc_signal,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END)-1.5)/1.5 AS spd_signal,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END))::int AS acc_flags_int,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END))::int AS spd_flags_int,
      public._cts_reliability_confidence(reliability) AS rel_factor,
      public._cts_distortion_severity(response_distortion) AS dist_sev,
      reliability AS rel, response_distortion AS dist,
      (SELECT jsonb_object_agg(competency, jsonb_build_object('a', lss_acc_weight, 's', lss_spd_weight))
       FROM public.hiregauge_competencies) AS w
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'maintains_high_activity', public._cts_lss_apply_v4(
      (28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op,
      (w->'maintains_high_activity'->>'a')::numeric, (w->'maintains_high_activity'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'listens_discovers_needs', public._cts_lss_apply_v4(
      (14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op,
      (w->'listens_discovers_needs'->>'a')::numeric, (w->'listens_discovers_needs'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'presents_solutions', public._cts_lss_apply_v4(
      (0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op,
      (w->'presents_solutions'->>'a')::numeric, (w->'presents_solutions'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'handles_objections', public._cts_lss_apply_v4(
      (-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op,
      (w->'handles_objections'->>'a')::numeric, (w->'handles_objections'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'receives_coaching', public._cts_lss_apply_v4(
      (33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op,
      (w->'receives_coaching'->>'a')::numeric, (w->'receives_coaching'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'positively_influences_team', public._cts_lss_apply_v4(
      op::numeric,
      (w->'positively_influences_team'->>'a')::numeric, (w->'positively_influences_team'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'retention_watchfulness', public._cts_lss_apply_v4(
      (20.000000) + (0.250000)*com + (0.200000)*an + (0.100000)*bo + (0.050000)*ass + (0.050000)*dm + (-0.050000)*op,
      (w->'retention_watchfulness'->>'a')::numeric, (w->'retention_watchfulness'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'proactive_touch_discipline', public._cts_lss_apply_v4(
      (20.000000) + (0.250000)*dm + (0.150000)*an + (0.150000)*com + (0.100000)*rd + (0.050000)*op,
      (w->'proactive_touch_discipline'->>'a')::numeric, (w->'proactive_touch_discipline'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    '_meta', jsonb_build_object(
      'has_lss', has_lss, 'acc_flags', acc_flags_int, 'spd_flags', spd_flags_int,
      'reliability', rel, 'distortion', dist,
      'reliability_factor', rel_factor, 'distortion_severity', dist_sev,
      'role', 'retention_escalation', 'model', 'sensitivity_weighted_v4_asymmetric'
    )
  )
  FROM adj;
$function$;


-- ============================================================================
-- 7. RETENTION SUPPORT (8 competencies)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cts_retention_support_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH adj AS (
    SELECT
      deadline_motivation AS dm, recognition_drive AS rd, assertiveness AS ass,
      independent_spirit AS is_val, analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      (lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL AND lss_problem_solving_accuracy IS NOT NULL
       AND lss_math_speed_seconds IS NOT NULL AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL) AS has_lss,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END)-1.5)/1.5 AS acc_signal,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END)-1.5)/1.5 AS spd_signal,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END))::int AS acc_flags_int,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END))::int AS spd_flags_int,
      public._cts_reliability_confidence(reliability) AS rel_factor,
      public._cts_distortion_severity(response_distortion) AS dist_sev,
      reliability AS rel, response_distortion AS dist,
      (SELECT jsonb_object_agg(competency, jsonb_build_object('a', lss_acc_weight, 's', lss_spd_weight))
       FROM public.hiregauge_competencies) AS w
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'manages_time_effectively', public._cts_lss_apply_v4(
      (33.197370) + (0.167938)*dm + (0.170463)*rd + (0.173435)*ass + (0.164096)*is_val + (-0.167532)*an + (-0.167799)*com + (0.001946)*sp + (-0.006913)*bo + (-0.005379)*op,
      (w->'manages_time_effectively'->>'a')::numeric, (w->'manages_time_effectively'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'makes_decisions_quickly', public._cts_lss_apply_v4(
      (28.788259) + (0.144387)*dm + (0.001618)*rd + (0.140225)*ass + (0.137139)*is_val + (-0.143650)*an + (-0.146024)*com + (0.147148)*sp + (-0.001939)*bo + (0.138712)*op,
      (w->'makes_decisions_quickly'->>'a')::numeric, (w->'makes_decisions_quickly'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'works_without_close_supervision', public._cts_lss_apply_v4(
      (0.014435) + (0.334137)*dm + (0.000589)*rd + (0.329735)*ass + (0.334420)*is_val + (0.001923)*an + (0.000663)*com + (-0.001501)*sp + (-0.002410)*bo + (-0.003302)*op,
      (w->'works_without_close_supervision'->>'a')::numeric, (w->'works_without_close_supervision'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'analytical', public._cts_lss_apply_v4(
      an::numeric,
      (w->'analytical'->>'a')::numeric, (w->'analytical'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'receives_coaching', public._cts_lss_apply_v4(
      (33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op,
      (w->'receives_coaching'->>'a')::numeric, (w->'receives_coaching'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'positively_influences_team', public._cts_lss_apply_v4(
      op::numeric,
      (w->'positively_influences_team'->>'a')::numeric, (w->'positively_influences_team'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'queue_throughput_discipline', public._cts_lss_apply_v4(
      (20.000000) + (0.250000)*dm + (0.150000)*an + (0.150000)*is_val + (0.100000)*rd + (0.050000)*op + (-0.050000)*sp,
      (w->'queue_throughput_discipline'->>'a')::numeric, (w->'queue_throughput_discipline'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'attention_to_detail', public._cts_lss_apply_v4(
      (20.000000) + (0.300000)*an + (0.150000)*dm + (0.100000)*com + (0.100000)*rd + (0.050000)*is_val,
      (w->'attention_to_detail'->>'a')::numeric, (w->'attention_to_detail'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    '_meta', jsonb_build_object(
      'has_lss', has_lss, 'acc_flags', acc_flags_int, 'spd_flags', spd_flags_int,
      'reliability', rel, 'distortion', dist,
      'reliability_factor', rel_factor, 'distortion_severity', dist_sev,
      'role', 'retention_support', 'model', 'sensitivity_weighted_v4_asymmetric'
    )
  )
  FROM adj;
$function$;


-- ============================================================================
-- 8. ASPIRANT (13 competencies)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cts_aspirant_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH adj AS (
    SELECT
      deadline_motivation AS dm, recognition_drive AS rd, assertiveness AS ass,
      independent_spirit AS is_val, analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      (lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL AND lss_problem_solving_accuracy IS NOT NULL
       AND lss_math_speed_seconds IS NOT NULL AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL) AS has_lss,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END)-1.5)/1.5 AS acc_signal,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END)-1.5)/1.5 AS spd_signal,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END))::int AS acc_flags_int,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END))::int AS spd_flags_int,
      public._cts_reliability_confidence(reliability) AS rel_factor,
      public._cts_distortion_severity(response_distortion) AS dist_sev,
      reliability AS rel, response_distortion AS dist,
      (SELECT jsonb_object_agg(competency, jsonb_build_object('a', lss_acc_weight, 's', lss_spd_weight))
       FROM public.hiregauge_competencies) AS w
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'maintains_high_activity', public._cts_lss_apply_v4(
      (28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op,
      (w->'maintains_high_activity'->>'a')::numeric, (w->'maintains_high_activity'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'handles_rejection', public._cts_lss_apply_v4(
      (21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op,
      (w->'handles_rejection'->>'a')::numeric, (w->'handles_rejection'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'prospects_in_community', public._cts_lss_apply_v4(
      (10.742427) + (-0.004516)*dm + (0.222510)*rd + (0.223384)*ass + (0.000353)*is_val + (-0.111467)*an + (0.106117)*com + (0.110739)*sp + (0.114601)*bo + (0.112072)*op,
      (w->'prospects_in_community'->>'a')::numeric, (w->'prospects_in_community'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'dials_cold_calls', public._cts_lss_apply_v4(
      (21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op,
      (w->'dials_cold_calls'->>'a')::numeric, (w->'dials_cold_calls'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'listens_discovers_needs', public._cts_lss_apply_v4(
      (14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op,
      (w->'listens_discovers_needs'->>'a')::numeric, (w->'listens_discovers_needs'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'presents_solutions', public._cts_lss_apply_v4(
      (0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op,
      (w->'presents_solutions'->>'a')::numeric, (w->'presents_solutions'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'handles_objections', public._cts_lss_apply_v4(
      (-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op,
      (w->'handles_objections'->>'a')::numeric, (w->'handles_objections'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'receives_coaching', public._cts_lss_apply_v4(
      (33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op,
      (w->'receives_coaching'->>'a')::numeric, (w->'receives_coaching'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'positively_influences_team', public._cts_lss_apply_v4(
      op::numeric,
      (w->'positively_influences_team'->>'a')::numeric, (w->'positively_influences_team'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'has_entrepreneurial_spirit', public._cts_lss_apply_v4(
      (0.052334) + (0.249428)*dm + (0.001218)*rd + (0.254556)*ass + (0.495006)*is_val + (-0.004124)*an + (-0.003403)*com + (0.006260)*sp + (-0.004916)*bo + (-0.003735)*op,
      (w->'has_entrepreneurial_spirit'->>'a')::numeric, (w->'has_entrepreneurial_spirit'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'balances_logic_and_emotion_when_hiring', public._cts_lss_apply_v4(
      (32.500522) + (0.001378)*dm + (-0.001370)*rd + (0.329501)*ass + (0.165831)*is_val + (0.162491)*an + (-0.163958)*com + (0.006637)*sp + (-0.168289)*bo + (0.003683)*op,
      (w->'balances_logic_and_emotion_when_hiring'->>'a')::numeric, (w->'balances_logic_and_emotion_when_hiring'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'is_fast_start_oriented', public._cts_lss_apply_v4(
      (-0.195183) + (0.402392)*dm + (0.201362)*rd + (0.202542)*ass + (0.198936)*is_val + (0.000119)*an + (-0.003170)*com + (-0.001383)*sp + (-0.001712)*bo + (0.000563)*op,
      (w->'is_fast_start_oriented'->>'a')::numeric, (w->'is_fast_start_oriented'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'competes_for_recognition', public._cts_lss_apply_v4(
      rd::numeric,
      (w->'competes_for_recognition'->>'a')::numeric, (w->'competes_for_recognition'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    '_meta', jsonb_build_object(
      'has_lss', has_lss, 'acc_flags', acc_flags_int, 'spd_flags', spd_flags_int,
      'reliability', rel, 'distortion', dist,
      'reliability_factor', rel_factor, 'distortion_severity', dist_sev,
      'role', 'aspirant', 'model', 'sensitivity_weighted_v4_asymmetric'
    )
  )
  FROM adj;
$function$;
