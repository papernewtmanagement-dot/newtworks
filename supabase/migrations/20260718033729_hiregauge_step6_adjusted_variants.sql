-- HireGauge Step 6: adjusted competency variants for 5 new roles
-- Adds: cts_sales_inbound_competencies_adjusted, cts_sales_in_book_competencies_adjusted,
--       cts_retention_reception_competencies_adjusted, cts_retention_escalation_competencies_adjusted,
--       cts_retention_support_competencies_adjusted
--
-- Mechanics: same scaffold as cts_sales_outbound_competencies_adjusted:
--   - Dampens compassion, belief_in_others, optimism via _cts_dampen_trait_by_distortion
--   - Wraps every competency score in _cts_finalize_competency(score, lss_mod, rel)
--     which applies LSS modifier + reliability regression toward 50
--   - Meta block with lss_modifier, reliability_confidence, distortion_severity
-- Retained Suggs comps reuse formulas byte-for-byte from base fns (Step 5).
-- New 10 hand-spec comps reuse formulas byte-for-byte from base fns (Step 5).
-- Signature: p_assessment_id uuid → jsonb. STABLE.
-- Non-additive risk: NONE. Pure adds.

------------------------------------------------------------
-- 1. cts_sales_inbound_competencies_adjusted
------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cts_sales_inbound_competencies_adjusted(p_assessment_id uuid)
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
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      reliability AS rel,
      response_distortion AS dist
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT
    jsonb_build_object(
      'maintains_high_activity', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op)::int)), lss_mod, rel),
      'handles_rejection', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)::int)), lss_mod, rel),
      'listens_discovers_needs', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)::int)), lss_mod, rel),
      'presents_solutions', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op)::int)), lss_mod, rel),
      'handles_objections', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op)::int)), lss_mod, rel),
      'receives_coaching', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)::int)), lss_mod, rel),
      'positively_influences_team', public._cts_finalize_competency(op, lss_mod, rel),
      'rapid_rapport_warm', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((20.000000) + (0.300000)*com + (0.200000)*op + (0.200000)*bo + (-0.100000)*an + (0.050000)*ass)::int)), lss_mod, rel),
      'cadence_compliance', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((22.000000) + (0.250000)*dm + (0.150000)*an + (0.150000)*rd + (0.100000)*bo + (0.050000)*op + (-0.100000)*is_val + (-0.050000)*sp)::int)), lss_mod, rel),
      '_meta', jsonb_build_object(
        'lss_modifier', lss_mod,
        'reliability_confidence', public._cts_reliability_confidence(rel),
        'distortion_severity', public._cts_distortion_severity(dist),
        'note', 'competency scores are dampened-for-distortion (socially-desirable ceilings) + LSS-modified + reliability-regressed toward 50'
      )
    )
  FROM adj;
$function$;

------------------------------------------------------------
-- 2. cts_sales_in_book_competencies_adjusted
------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cts_sales_in_book_competencies_adjusted(p_assessment_id uuid)
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
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      reliability AS rel,
      response_distortion AS dist
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT
    jsonb_build_object(
      'maintains_high_activity', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op)::int)), lss_mod, rel),
      'handles_rejection', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)::int)), lss_mod, rel),
      'listens_discovers_needs', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)::int)), lss_mod, rel),
      'presents_solutions', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op)::int)), lss_mod, rel),
      'handles_objections', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op)::int)), lss_mod, rel),
      'receives_coaching', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)::int)), lss_mod, rel),
      'positively_influences_team', public._cts_finalize_competency(op, lss_mod, rel),
      'cross_sell_instinct', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((10.000000) + (0.200000)*com + (0.200000)*an + (0.150000)*sp + (0.100000)*bo + (0.100000)*rd + (0.050000)*dm + (0.050000)*ass + (-0.050000)*is_val)::int)), lss_mod, rel),
      'retention_watchfulness', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*com + (0.200000)*an + (0.100000)*bo + (0.050000)*ass + (0.050000)*dm + (-0.050000)*op)::int)), lss_mod, rel),
      '_meta', jsonb_build_object(
        'lss_modifier', lss_mod,
        'reliability_confidence', public._cts_reliability_confidence(rel),
        'distortion_severity', public._cts_distortion_severity(dist),
        'note', 'competency scores are dampened-for-distortion (socially-desirable ceilings) + LSS-modified + reliability-regressed toward 50'
      )
    )
  FROM adj;
$function$;

------------------------------------------------------------
-- 3. cts_retention_reception_competencies_adjusted
------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cts_retention_reception_competencies_adjusted(p_assessment_id uuid)
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
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      reliability AS rel,
      response_distortion AS dist
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT
    jsonb_build_object(
      'listens_discovers_needs', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)::int)), lss_mod, rel),
      'makes_decisions_quickly', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.788259) + (0.144387)*dm + (0.001618)*rd + (0.140225)*ass + (0.137139)*is_val + (-0.143650)*an + (-0.146024)*com + (0.147148)*sp + (-0.001939)*bo + (0.138712)*op)::int)), lss_mod, rel),
      'receives_coaching', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)::int)), lss_mod, rel),
      'positively_influences_team', public._cts_finalize_competency(op, lss_mod, rel),
      'rapid_rapport_warm', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((20.000000) + (0.300000)*com + (0.200000)*op + (0.200000)*bo + (-0.100000)*an + (0.050000)*ass)::int)), lss_mod, rel),
      'routing_judgment', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((22.000000) + (0.250000)*an + (0.200000)*bo + (0.150000)*com + (0.050000)*dm + (0.050000)*op + (0.050000)*ass + (-0.100000)*is_val + (-0.100000)*sp)::int)), lss_mod, rel),
      'composure_under_load', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((18.000000) + (0.250000)*op + (0.200000)*com + (0.100000)*ass + (0.050000)*is_val + (0.050000)*dm + (0.050000)*bo + (-0.050000)*an)::int)), lss_mod, rel),
      'pivots_to_customer_need', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((12.000000) + (0.250000)*com + (0.200000)*an + (0.150000)*ass + (0.100000)*op + (0.100000)*bo + (0.050000)*rd + (-0.050000)*is_val + (-0.050000)*sp)::int)), lss_mod, rel),
      '_meta', jsonb_build_object(
        'lss_modifier', lss_mod,
        'reliability_confidence', public._cts_reliability_confidence(rel),
        'distortion_severity', public._cts_distortion_severity(dist),
        'note', 'competency scores are dampened-for-distortion (socially-desirable ceilings) + LSS-modified + reliability-regressed toward 50'
      )
    )
  FROM adj;
$function$;

------------------------------------------------------------
-- 4. cts_retention_escalation_competencies_adjusted
------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cts_retention_escalation_competencies_adjusted(p_assessment_id uuid)
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
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      reliability AS rel,
      response_distortion AS dist
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT
    jsonb_build_object(
      'maintains_high_activity', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op)::int)), lss_mod, rel),
      'listens_discovers_needs', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)::int)), lss_mod, rel),
      'presents_solutions', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op)::int)), lss_mod, rel),
      'handles_objections', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op)::int)), lss_mod, rel),
      'receives_coaching', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)::int)), lss_mod, rel),
      'positively_influences_team', public._cts_finalize_competency(op, lss_mod, rel),
      'retention_watchfulness', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*com + (0.200000)*an + (0.100000)*bo + (0.050000)*ass + (0.050000)*dm + (-0.050000)*op)::int)), lss_mod, rel),
      'proactive_touch_discipline', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*dm + (0.150000)*an + (0.150000)*com + (0.100000)*rd + (0.050000)*op + (-0.050000)*is_val + (-0.050000)*sp)::int)), lss_mod, rel),
      '_meta', jsonb_build_object(
        'lss_modifier', lss_mod,
        'reliability_confidence', public._cts_reliability_confidence(rel),
        'distortion_severity', public._cts_distortion_severity(dist),
        'note', 'competency scores are dampened-for-distortion (socially-desirable ceilings) + LSS-modified + reliability-regressed toward 50'
      )
    )
  FROM adj;
$function$;

------------------------------------------------------------
-- 5. cts_retention_support_competencies_adjusted
------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cts_retention_support_competencies_adjusted(p_assessment_id uuid)
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
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      reliability AS rel,
      response_distortion AS dist
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT
    jsonb_build_object(
      'manages_time_effectively', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.197370) + (0.167938)*dm + (0.170463)*rd + (0.173435)*ass + (0.164096)*is_val + (-0.167532)*an + (-0.167799)*com + (0.001946)*sp + (-0.006913)*bo + (-0.005379)*op)::int)), lss_mod, rel),
      'makes_decisions_quickly', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((28.788259) + (0.144387)*dm + (0.001618)*rd + (0.140225)*ass + (0.137139)*is_val + (-0.143650)*an + (-0.146024)*com + (0.147148)*sp + (-0.001939)*bo + (0.138712)*op)::int)), lss_mod, rel),
      'works_without_close_supervision', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((0.014435) + (0.334137)*dm + (0.000589)*rd + (0.329735)*ass + (0.334420)*is_val + (0.001923)*an + (0.000663)*com + (-0.001501)*sp + (-0.002410)*bo + (-0.003302)*op)::int)), lss_mod, rel),
      'analytical', public._cts_finalize_competency(an, lss_mod, rel),
      'receives_coaching', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)::int)), lss_mod, rel),
      'positively_influences_team', public._cts_finalize_competency(op, lss_mod, rel),
      'queue_throughput_discipline', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*dm + (0.150000)*an + (0.150000)*is_val + (0.100000)*rd + (0.050000)*op + (-0.100000)*sp)::int)), lss_mod, rel),
      'attention_to_detail', public._cts_finalize_competency(GREATEST(0, LEAST(100, ROUND((20.000000) + (0.300000)*an + (0.150000)*dm + (0.100000)*com + (0.100000)*rd + (0.050000)*is_val + (-0.050000)*op + (-0.050000)*sp)::int)), lss_mod, rel),
      '_meta', jsonb_build_object(
        'lss_modifier', lss_mod,
        'reliability_confidence', public._cts_reliability_confidence(rel),
        'distortion_severity', public._cts_distortion_severity(dist),
        'note', 'competency scores are dampened-for-distortion (socially-desirable ceilings) + LSS-modified + reliability-regressed toward 50'
      )
    )
  FROM adj;
$function$;
