-- =====================================================================
-- Phase 1e correction (per Peter feedback 2026-07-16):
-- 1. Split distortion (targeted socially-desirable dampening) from
--    reliability (bidirectional regression-to-mean on competency).
-- 2. Per-layer verdicts + retrospective as separate signal +
--    calibration status. Framework verdict independent of retrospective.
-- =====================================================================

-- Drop old validity helpers (superseded)
DROP FUNCTION IF EXISTS public._cts_dampen_trait(integer, text, text);
DROP FUNCTION IF EXISTS public._cts_validity_severity(text, text);

-- New: distortion severity (0 / 0.6 / 1.0)
CREATE OR REPLACE FUNCTION public._cts_distortion_severity(p_distortion text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_distortion
    WHEN 'high' THEN 1.0
    WHEN 'moderate' THEN 0.6
    ELSE 0.0
  END::numeric;
$$;

COMMENT ON FUNCTION public._cts_distortion_severity(text) IS
'0.0 (LOW distortion) to 1.0 (HIGH). Scales targeted ceiling dampening of socially-desirable traits.';

-- New: reliability confidence (regression-to-mean factor)
CREATE OR REPLACE FUNCTION public._cts_reliability_confidence(p_reliability text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_reliability
    WHEN 'very_high' THEN 1.0
    WHEN 'high' THEN 1.0
    WHEN 'moderate' THEN 0.85
    WHEN 'low' THEN 0.65
    ELSE 0.9
  END::numeric;
$$;

COMMENT ON FUNCTION public._cts_reliability_confidence(text) IS
'Confidence factor for reliability. 1.0 = full trust; below 1.0 = regress competency toward 50 (mean). Applies bidirectionally.';

-- New: targeted distortion dampening on socially-desirable traits (COM, OP, BO)
-- Traits > 65 dampened by up to 10 points at severity=1.0. Other traits untouched.
CREATE OR REPLACE FUNCTION public._cts_dampen_trait_by_distortion(
  p_trait integer, p_trait_name text, p_distortion text
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_trait IS NULL THEN NULL
    WHEN p_trait_name NOT IN ('compassion', 'optimism', 'belief_in_others') THEN p_trait
    WHEN p_trait <= 65 THEN p_trait
    ELSE GREATEST(65, p_trait - (10 * public._cts_distortion_severity(p_distortion))::int)
  END;
$$;

COMMENT ON FUNCTION public._cts_dampen_trait_by_distortion(integer, text, text) IS
'Targeted ceiling dampening only for socially-desirable traits: compassion, optimism, belief_in_others. Traits > 65 reduced up to 10 points at distortion severity 1.0. Floors preserved.';

-- New: regression-to-mean helper for reliability confidence
CREATE OR REPLACE FUNCTION public._cts_apply_reliability_confidence(
  p_score integer, p_reliability text
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE 
    WHEN p_score IS NULL THEN NULL
    ELSE GREATEST(0, LEAST(100, ROUND(50 + (p_score - 50) * public._cts_reliability_confidence(p_reliability))::int))
  END;
$$;

COMMENT ON FUNCTION public._cts_apply_reliability_confidence(integer, text) IS
'Regression-to-mean: pulls competency scores toward 50 by (1 - confidence). Bidirectional — dampens both high AND low extremes when reliability is uncertain.';

-- New: finalize helper (applies LSS modifier + reliability regression in one step)
CREATE OR REPLACE FUNCTION public._cts_finalize_competency(
  p_raw_score integer, p_lss_modifier numeric, p_reliability text
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_raw_score IS NULL THEN NULL
    ELSE public._cts_apply_reliability_confidence(
      GREATEST(0, LEAST(100, ROUND(p_raw_score * (1 + COALESCE(p_lss_modifier, 0)))::int)),
      p_reliability
    )
  END;
$$;

COMMENT ON FUNCTION public._cts_finalize_competency(integer, numeric, text) IS
'One-step: apply LSS multiplicative modifier + reliability regression-to-mean. Used inside adjusted competency functions.';

-- =====================================================================
-- Rewrite the 4 adjusted competency functions with new dampening logic
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cts_sales_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$
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
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      reliability AS rel,
      response_distortion AS dist
    FROM public.team_assessments
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT
    jsonb_build_object(
      'maintains_high_activity', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op)::int)), lss_mod, rel),
      'handles_rejection', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)::int)), lss_mod, rel),
      'prospects_in_community', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((10.742427) + (-0.004516)*dm + (0.222510)*rd + (0.223384)*ass + (0.000353)*is_val + (-0.111467)*an + (0.106117)*com + (0.110739)*sp + (0.114601)*bo + (0.112072)*op)::int)), lss_mod, rel),
      'dials_cold_calls', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)::int)), lss_mod, rel),
      'listens_discovers_needs', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)::int)), lss_mod, rel),
      'presents_solutions', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op)::int)), lss_mod, rel),
      'handles_objections', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op)::int)), lss_mod, rel),
      'receives_coaching', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)::int)), lss_mod, rel),
      'positively_influences_team', public._cts_finalize_competency(op, lss_mod, rel),
      '_meta', jsonb_build_object(
        'lss_modifier', lss_mod,
        'reliability_confidence', public._cts_reliability_confidence(rel),
        'distortion_severity', public._cts_distortion_severity(dist),
        'note', 'competency scores are dampened-for-distortion (socially-desirable ceilings) + LSS-modified + reliability-regressed toward 50'
      )
    )
  FROM adj;
$$;

CREATE OR REPLACE FUNCTION public.cts_service_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH adj AS (
    SELECT
      deadline_motivation AS dm, recognition_drive AS rd, assertiveness AS ass,
      independent_spirit AS is_val, analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      reliability AS rel, response_distortion AS dist
    FROM public.team_assessments
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'manages_time_effectively', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.197370) + (0.167938)*dm + (0.170463)*rd + (0.173435)*ass + (0.164096)*is_val + (-0.167532)*an + (-0.167799)*com + (0.001946)*sp + (-0.006913)*bo + (-0.005379)*op)::int)), lss_mod, rel),
    'makes_decisions_quickly', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.788259) + (0.144387)*dm + (0.001618)*rd + (0.140225)*ass + (0.137139)*is_val + (-0.143650)*an + (-0.146024)*com + (0.147148)*sp + (-0.001939)*bo + (0.138712)*op)::int)), lss_mod, rel),
    'works_without_close_supervision', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.014435) + (0.334137)*dm + (0.000589)*rd + (0.329735)*ass + (0.334420)*is_val + (0.001923)*an + (0.000663)*com + (-0.001501)*sp + (-0.002410)*bo + (-0.003302)*op)::int)), lss_mod, rel),
    'analytical', public._cts_finalize_competency(an, lss_mod, rel),
    'pivots_schedules_appointments', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((-0.246547) + (0.000576)*dm + (0.499865)*rd + (0.495410)*ass + (0.000871)*is_val + (-0.001861)*an + (0.003769)*com + (-0.002526)*sp + (0.003220)*bo + (0.000872)*op)::int)), lss_mod, rel),
    'builds_relationships', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((16.278094) + (0.003039)*dm + (0.166042)*rd + (0.164833)*ass + (0.001261)*is_val + (-0.157346)*an + (0.334947)*com + (-0.008260)*sp + (0.166155)*bo + (-0.001070)*op)::int)), lss_mod, rel),
    'receives_coaching', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)::int)), lss_mod, rel),
    'positively_influences_team', public._cts_finalize_competency(op, lss_mod, rel),
    '_meta', jsonb_build_object('lss_modifier', lss_mod, 'reliability_confidence', public._cts_reliability_confidence(rel), 'distortion_severity', public._cts_distortion_severity(dist))
  ) FROM adj;
$$;

CREATE OR REPLACE FUNCTION public.cts_service_sales_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH adj AS (
    SELECT
      deadline_motivation AS dm, recognition_drive AS rd, assertiveness AS ass,
      independent_spirit AS is_val, analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      reliability AS rel, response_distortion AS dist
    FROM public.team_assessments
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'manages_time_effectively', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.197370) + (0.167938)*dm + (0.170463)*rd + (0.173435)*ass + (0.164096)*is_val + (-0.167532)*an + (-0.167799)*com + (0.001946)*sp + (-0.006913)*bo + (-0.005379)*op)::int)), lss_mod, rel),
    'makes_decisions_quickly', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.788259) + (0.144387)*dm + (0.001618)*rd + (0.140225)*ass + (0.137139)*is_val + (-0.143650)*an + (-0.146024)*com + (0.147148)*sp + (-0.001939)*bo + (0.138712)*op)::int)), lss_mod, rel),
    'works_without_close_supervision', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.014435) + (0.334137)*dm + (0.000589)*rd + (0.329735)*ass + (0.334420)*is_val + (0.001923)*an + (0.000663)*com + (-0.001501)*sp + (-0.002410)*bo + (-0.003302)*op)::int)), lss_mod, rel),
    'analytical', public._cts_finalize_competency(an, lss_mod, rel),
    'builds_relationships', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((16.278094) + (0.003039)*dm + (0.166042)*rd + (0.164833)*ass + (0.001261)*is_val + (-0.157346)*an + (0.334947)*com + (-0.008260)*sp + (0.166155)*bo + (-0.001070)*op)::int)), lss_mod, rel),
    'receives_coaching', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)::int)), lss_mod, rel),
    'positively_influences_team', public._cts_finalize_competency(op, lss_mod, rel),
    'maintains_high_activity', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op)::int)), lss_mod, rel),
    'handles_rejection', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)::int)), lss_mod, rel),
    'prospects_in_community', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((10.742427) + (-0.004516)*dm + (0.222510)*rd + (0.223384)*ass + (0.000353)*is_val + (-0.111467)*an + (0.106117)*com + (0.110739)*sp + (0.114601)*bo + (0.112072)*op)::int)), lss_mod, rel),
    'dials_cold_calls', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)::int)), lss_mod, rel),
    'listens_discovers_needs', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)::int)), lss_mod, rel),
    'presents_solutions', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op)::int)), lss_mod, rel),
    'handles_objections', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op)::int)), lss_mod, rel),
    '_meta', jsonb_build_object('lss_modifier', lss_mod, 'reliability_confidence', public._cts_reliability_confidence(rel), 'distortion_severity', public._cts_distortion_severity(dist))
  ) FROM adj;
$$;

CREATE OR REPLACE FUNCTION public.cts_aspirant_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH adj AS (
    SELECT
      deadline_motivation AS dm, recognition_drive AS rd, assertiveness AS ass,
      independent_spirit AS is_val, analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      reliability AS rel, response_distortion AS dist
    FROM public.team_assessments
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'maintains_high_activity', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op)::int)), lss_mod, rel),
    'handles_rejection', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)::int)), lss_mod, rel),
    'prospects_in_community', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((10.742427) + (-0.004516)*dm + (0.222510)*rd + (0.223384)*ass + (0.000353)*is_val + (-0.111467)*an + (0.106117)*com + (0.110739)*sp + (0.114601)*bo + (0.112072)*op)::int)), lss_mod, rel),
    'dials_cold_calls', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)::int)), lss_mod, rel),
    'listens_discovers_needs', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)::int)), lss_mod, rel),
    'presents_solutions', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op)::int)), lss_mod, rel),
    'handles_objections', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op)::int)), lss_mod, rel),
    'receives_coaching', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)::int)), lss_mod, rel),
    'positively_influences_team', public._cts_finalize_competency(op, lss_mod, rel),
    'has_entrepreneurial_spirit', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.052334) + (0.249428)*dm + (0.001218)*rd + (0.254556)*ass + (0.495006)*is_val + (-0.004124)*an + (-0.003403)*com + (0.006260)*sp + (-0.004916)*bo + (-0.003735)*op)::int)), lss_mod, rel),
    'balances_logic_and_emotion_when_hiring', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((32.500522) + (0.001378)*dm + (-0.001370)*rd + (0.329501)*ass + (0.165831)*is_val + (0.162491)*an + (-0.163958)*com + (0.006637)*sp + (-0.168289)*bo + (0.003683)*op)::int)), lss_mod, rel),
    'is_fast_start_oriented', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((-0.195183) + (0.402392)*dm + (0.201362)*rd + (0.202542)*ass + (0.198936)*is_val + (0.000119)*an + (-0.003170)*com + (-0.001383)*sp + (-0.001712)*bo + (0.000563)*op)::int)), lss_mod, rel),
    'competes_for_recognition', public._cts_finalize_competency(rd, lss_mod, rel),
    '_meta', jsonb_build_object('lss_modifier', lss_mod, 'reliability_confidence', public._cts_reliability_confidence(rel), 'distortion_severity', public._cts_distortion_severity(dist))
  ) FROM adj;
$$;
