-- Migration 20260721002910 (mirror of applied migration)
-- HireGauge LSS per-competency weighting sprint — Step 3
--
-- Rewrites 3 sales _competencies_adjusted fns + adds helper _cts_lss_apply_v4 to:
--   1. Read per-competency lss_acc_weight + lss_spd_weight from hiregauge_competencies
--   2. Apply v4 asymmetric flag counting: acc >= low_bound, spd <= high_bound
--   3. Per-competency lss_delta = 15 * (acc_wt * acc_signal + spd_wt * spd_signal) / 2
--   4. Preserve flat integer output shape (frontend reads competencies[role] as flat map)
--   5. Preserve trait-formula bases, distortion dampening, reliability regression
--
-- Helper _cts_lss_apply_v4 replaces uniform _cts_lss_modifier + _cts_finalize_competency path.
-- Old helpers kept in place for now (audit before drop pending).
-- Retention + aspirant fns rewritten in follow-up migration 20260721003058.

CREATE OR REPLACE FUNCTION public._cts_lss_apply_v4(
  p_base numeric,
  p_acc_wt numeric,
  p_spd_wt numeric,
  p_acc_signal numeric,
  p_spd_signal numeric,
  p_rel_factor numeric,
  p_has_lss boolean
) RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_lss_delta numeric := 0;
  v_pre_rel numeric;
BEGIN
  IF p_base IS NULL THEN RETURN NULL; END IF;
  IF p_has_lss THEN
    v_lss_delta := 15.0 * (COALESCE(p_acc_wt, 0) * p_acc_signal + COALESCE(p_spd_wt, 0) * p_spd_signal) / 2.0;
  END IF;
  v_pre_rel := GREATEST(0, LEAST(100, ROUND(p_base + v_lss_delta)));
  RETURN GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * COALESCE(p_rel_factor, 1.0))))::int;
END;
$$;

COMMENT ON FUNCTION public._cts_lss_apply_v4 IS
  'Per-competency v4 asymmetric LSS applier. Takes trait-formula base, per-competency LSS weights, candidate LSS signals, and reliability factor. Returns final integer 0-100. Replaces uniform _cts_lss_modifier + _cts_finalize_competency path for role competency fns.';


-- ============================================================================
-- 2. SALES OUTBOUND (9 competencies)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cts_sales_outbound_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH adj AS (
    SELECT
      deadline_motivation AS dm,
      recognition_drive AS rd,
      assertiveness AS ass,
      independent_spirit AS is_val,
      analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      (lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL AND lss_problem_solving_accuracy IS NOT NULL
       AND lss_math_speed_seconds IS NOT NULL AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL) AS has_lss,
      ((CASE WHEN lss_math_accuracy              >= 10 THEN 1 ELSE 0 END)
     + (CASE WHEN lss_verbal_accuracy            >=  8 THEN 1 ELSE 0 END)
     + (CASE WHEN lss_problem_solving_accuracy   >=  7 THEN 1 ELSE 0 END) - 1.5) / 1.5 AS acc_signal,
      ((CASE WHEN lss_math_speed_seconds            <= 50 THEN 1 ELSE 0 END)
     + (CASE WHEN lss_verbal_speed_seconds          <= 52 THEN 1 ELSE 0 END)
     + (CASE WHEN lss_problem_solving_speed_seconds <= 77 THEN 1 ELSE 0 END) - 1.5) / 1.5 AS spd_signal,
      ((CASE WHEN lss_math_accuracy              >= 10 THEN 1 ELSE 0 END)
     + (CASE WHEN lss_verbal_accuracy            >=  8 THEN 1 ELSE 0 END)
     + (CASE WHEN lss_problem_solving_accuracy   >=  7 THEN 1 ELSE 0 END))::int AS acc_flags_int,
      ((CASE WHEN lss_math_speed_seconds            <= 50 THEN 1 ELSE 0 END)
     + (CASE WHEN lss_verbal_speed_seconds          <= 52 THEN 1 ELSE 0 END)
     + (CASE WHEN lss_problem_solving_speed_seconds <= 77 THEN 1 ELSE 0 END))::int AS spd_flags_int,
      public._cts_reliability_confidence(reliability) AS rel_factor,
      public._cts_distortion_severity(response_distortion) AS dist_sev,
      reliability AS rel,
      response_distortion AS dist,
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
    '_meta', jsonb_build_object(
      'has_lss',             has_lss,
      'acc_flags',           acc_flags_int,
      'spd_flags',           spd_flags_int,
      'reliability',         rel,
      'distortion',          dist,
      'reliability_factor',  rel_factor,
      'distortion_severity', dist_sev,
      'role',                'sales_outbound',
      'model',               'sensitivity_weighted_v4_asymmetric'
    )
  )
  FROM adj;
$function$;


-- ============================================================================
-- 3. SALES INBOUND (9 competencies)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cts_sales_inbound_competencies_adjusted(p_assessment_id uuid)
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
    'rapid_rapport_warm', public._cts_lss_apply_v4(
      (20.000000) + (0.300000)*com + (0.200000)*op + (0.200000)*bo + (-0.050000)*an + (0.050000)*ass,
      (w->'rapid_rapport_warm'->>'a')::numeric, (w->'rapid_rapport_warm'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'cadence_compliance', public._cts_lss_apply_v4(
      (22.000000) + (0.250000)*dm + (0.150000)*an + (0.150000)*rd + (0.050000)*op + (-0.050000)*is_val,
      (w->'cadence_compliance'->>'a')::numeric, (w->'cadence_compliance'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    '_meta', jsonb_build_object(
      'has_lss', has_lss, 'acc_flags', acc_flags_int, 'spd_flags', spd_flags_int,
      'reliability', rel, 'distortion', dist,
      'reliability_factor', rel_factor, 'distortion_severity', dist_sev,
      'role', 'sales_inbound', 'model', 'sensitivity_weighted_v4_asymmetric'
    )
  )
  FROM adj;
$function$;


-- ============================================================================
-- 4. SALES IN-BOOK (9 competencies)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.cts_sales_in_book_competencies_adjusted(p_assessment_id uuid)
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
    'cross_sell_instinct', public._cts_lss_apply_v4(
      (10.000000) + (0.200000)*com + (0.200000)*an + (0.150000)*sp + (0.100000)*bo + (0.100000)*rd + (0.050000)*dm + (0.050000)*ass,
      (w->'cross_sell_instinct'->>'a')::numeric, (w->'cross_sell_instinct'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    'retention_watchfulness', public._cts_lss_apply_v4(
      (20.000000) + (0.250000)*com + (0.200000)*an + (0.100000)*bo + (0.050000)*ass + (0.050000)*dm + (-0.050000)*op,
      (w->'retention_watchfulness'->>'a')::numeric, (w->'retention_watchfulness'->>'s')::numeric,
      acc_signal, spd_signal, rel_factor, has_lss),
    '_meta', jsonb_build_object(
      'has_lss', has_lss, 'acc_flags', acc_flags_int, 'spd_flags', spd_flags_int,
      'reliability', rel, 'distortion', dist,
      'reliability_factor', rel_factor, 'distortion_severity', dist_sev,
      'role', 'sales_in_book', 'model', 'sensitivity_weighted_v4_asymmetric'
    )
  )
  FROM adj;
$function$;
