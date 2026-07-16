-- =====================================================================
-- Phase 1b: LSS + validity-adjusted competency functions per role
-- Take assessment_id, return jsonb of adjusted competency scores.
-- Existing raw competency functions (9-trait signature) preserved untouched
-- for HireGauge rule-engine backward compat.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cts_sales_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH ta AS (
    SELECT * FROM public.team_assessments WHERE id = p_assessment_id
  ),
  adj AS (
    SELECT
      public._cts_dampen_trait(deadline_motivation, reliability, response_distortion) AS dm,
      public._cts_dampen_trait(recognition_drive, reliability, response_distortion) AS rd,
      public._cts_dampen_trait(assertiveness, reliability, response_distortion) AS ass,
      public._cts_dampen_trait(independent_spirit, reliability, response_distortion) AS is_val,
      public._cts_dampen_trait(analytical, reliability, response_distortion) AS an,
      public._cts_dampen_trait(compassion, reliability, response_distortion) AS com,
      public._cts_dampen_trait(self_promotion, reliability, response_distortion) AS sp,
      public._cts_dampen_trait(belief_in_others, reliability, response_distortion) AS bo,
      public._cts_dampen_trait(optimism, reliability, response_distortion) AS op,
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      public._cts_validity_severity(reliability, response_distortion) AS val_sev
    FROM ta
  )
  SELECT
    CASE
      WHEN NOT EXISTS (SELECT 1 FROM adj WHERE dm IS NOT NULL) THEN NULL
      ELSE (
        SELECT jsonb_build_object(
          'maintains_high_activity', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op)) * (1 + lss_mod))::int)),
          'handles_rejection', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)) * (1 + lss_mod))::int)),
          'prospects_in_community', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (10.742427) + (-0.004516)*dm + (0.222510)*rd + (0.223384)*ass + (0.000353)*is_val + (-0.111467)*an + (0.106117)*com + (0.110739)*sp + (0.114601)*bo + (0.112072)*op)) * (1 + lss_mod))::int)),
          'dials_cold_calls', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)) * (1 + lss_mod))::int)),
          'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)) * (1 + lss_mod))::int)),
          'presents_solutions', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op)) * (1 + lss_mod))::int)),
          'handles_objections', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op)) * (1 + lss_mod))::int)),
          'receives_coaching', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)) * (1 + lss_mod))::int)),
          'positively_influences_team', GREATEST(0, LEAST(100, ROUND(op * (1 + lss_mod))::int)),
          '_meta', jsonb_build_object(
            'lss_modifier', lss_mod,
            'validity_severity', val_sev,
            'note', 'competency scores are LSS + validity-adjusted; raw traits stored on team_assessments'
          )
        )
        FROM adj
      )
    END
  FROM adj;
$$;

CREATE OR REPLACE FUNCTION public.cts_service_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH ta AS (
    SELECT * FROM public.team_assessments WHERE id = p_assessment_id
  ),
  adj AS (
    SELECT
      public._cts_dampen_trait(deadline_motivation, reliability, response_distortion) AS dm,
      public._cts_dampen_trait(recognition_drive, reliability, response_distortion) AS rd,
      public._cts_dampen_trait(assertiveness, reliability, response_distortion) AS ass,
      public._cts_dampen_trait(independent_spirit, reliability, response_distortion) AS is_val,
      public._cts_dampen_trait(analytical, reliability, response_distortion) AS an,
      public._cts_dampen_trait(compassion, reliability, response_distortion) AS com,
      public._cts_dampen_trait(self_promotion, reliability, response_distortion) AS sp,
      public._cts_dampen_trait(belief_in_others, reliability, response_distortion) AS bo,
      public._cts_dampen_trait(optimism, reliability, response_distortion) AS op,
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      public._cts_validity_severity(reliability, response_distortion) AS val_sev
    FROM ta
  )
  SELECT
    CASE
      WHEN NOT EXISTS (SELECT 1 FROM adj WHERE dm IS NOT NULL) THEN NULL
      ELSE (
        SELECT jsonb_build_object(
          'manages_time_effectively', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (33.197370) + (0.167938)*dm + (0.170463)*rd + (0.173435)*ass + (0.164096)*is_val + (-0.167532)*an + (-0.167799)*com + (0.001946)*sp + (-0.006913)*bo + (-0.005379)*op)) * (1 + lss_mod))::int)),
          'makes_decisions_quickly', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (28.788259) + (0.144387)*dm + (0.001618)*rd + (0.140225)*ass + (0.137139)*is_val + (-0.143650)*an + (-0.146024)*com + (0.147148)*sp + (-0.001939)*bo + (0.138712)*op)) * (1 + lss_mod))::int)),
          'works_without_close_supervision', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (0.014435) + (0.334137)*dm + (0.000589)*rd + (0.329735)*ass + (0.334420)*is_val + (0.001923)*an + (0.000663)*com + (-0.001501)*sp + (-0.002410)*bo + (-0.003302)*op)) * (1 + lss_mod))::int)),
          'analytical', GREATEST(0, LEAST(100, ROUND(an * (1 + lss_mod))::int)),
          'pivots_schedules_appointments', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (-0.246547) + (0.000576)*dm + (0.499865)*rd + (0.495410)*ass + (0.000871)*is_val + (-0.001861)*an + (0.003769)*com + (-0.002526)*sp + (0.003220)*bo + (0.000872)*op)) * (1 + lss_mod))::int)),
          'builds_relationships', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (16.278094) + (0.003039)*dm + (0.166042)*rd + (0.164833)*ass + (0.001261)*is_val + (-0.157346)*an + (0.334947)*com + (-0.008260)*sp + (0.166155)*bo + (-0.001070)*op)) * (1 + lss_mod))::int)),
          'receives_coaching', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)) * (1 + lss_mod))::int)),
          'positively_influences_team', GREATEST(0, LEAST(100, ROUND(op * (1 + lss_mod))::int)),
          '_meta', jsonb_build_object('lss_modifier', lss_mod, 'validity_severity', val_sev)
        )
        FROM adj
      )
    END
  FROM adj;
$$;

CREATE OR REPLACE FUNCTION public.cts_service_sales_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH ta AS (
    SELECT * FROM public.team_assessments WHERE id = p_assessment_id
  ),
  adj AS (
    SELECT
      public._cts_dampen_trait(deadline_motivation, reliability, response_distortion) AS dm,
      public._cts_dampen_trait(recognition_drive, reliability, response_distortion) AS rd,
      public._cts_dampen_trait(assertiveness, reliability, response_distortion) AS ass,
      public._cts_dampen_trait(independent_spirit, reliability, response_distortion) AS is_val,
      public._cts_dampen_trait(analytical, reliability, response_distortion) AS an,
      public._cts_dampen_trait(compassion, reliability, response_distortion) AS com,
      public._cts_dampen_trait(self_promotion, reliability, response_distortion) AS sp,
      public._cts_dampen_trait(belief_in_others, reliability, response_distortion) AS bo,
      public._cts_dampen_trait(optimism, reliability, response_distortion) AS op,
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      public._cts_validity_severity(reliability, response_distortion) AS val_sev
    FROM ta
  )
  SELECT
    CASE
      WHEN NOT EXISTS (SELECT 1 FROM adj WHERE dm IS NOT NULL) THEN NULL
      ELSE (
        SELECT jsonb_build_object(
          'manages_time_effectively', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (33.197370) + (0.167938)*dm + (0.170463)*rd + (0.173435)*ass + (0.164096)*is_val + (-0.167532)*an + (-0.167799)*com + (0.001946)*sp + (-0.006913)*bo + (-0.005379)*op)) * (1 + lss_mod))::int)),
          'makes_decisions_quickly', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (28.788259) + (0.144387)*dm + (0.001618)*rd + (0.140225)*ass + (0.137139)*is_val + (-0.143650)*an + (-0.146024)*com + (0.147148)*sp + (-0.001939)*bo + (0.138712)*op)) * (1 + lss_mod))::int)),
          'works_without_close_supervision', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (0.014435) + (0.334137)*dm + (0.000589)*rd + (0.329735)*ass + (0.334420)*is_val + (0.001923)*an + (0.000663)*com + (-0.001501)*sp + (-0.002410)*bo + (-0.003302)*op)) * (1 + lss_mod))::int)),
          'analytical', GREATEST(0, LEAST(100, ROUND(an * (1 + lss_mod))::int)),
          'builds_relationships', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (16.278094) + (0.003039)*dm + (0.166042)*rd + (0.164833)*ass + (0.001261)*is_val + (-0.157346)*an + (0.334947)*com + (-0.008260)*sp + (0.166155)*bo + (-0.001070)*op)) * (1 + lss_mod))::int)),
          'receives_coaching', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)) * (1 + lss_mod))::int)),
          'positively_influences_team', GREATEST(0, LEAST(100, ROUND(op * (1 + lss_mod))::int)),
          'maintains_high_activity', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op)) * (1 + lss_mod))::int)),
          'handles_rejection', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)) * (1 + lss_mod))::int)),
          'prospects_in_community', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (10.742427) + (-0.004516)*dm + (0.222510)*rd + (0.223384)*ass + (0.000353)*is_val + (-0.111467)*an + (0.106117)*com + (0.110739)*sp + (0.114601)*bo + (0.112072)*op)) * (1 + lss_mod))::int)),
          'dials_cold_calls', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)) * (1 + lss_mod))::int)),
          'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)) * (1 + lss_mod))::int)),
          'presents_solutions', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op)) * (1 + lss_mod))::int)),
          'handles_objections', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op)) * (1 + lss_mod))::int)),
          '_meta', jsonb_build_object('lss_modifier', lss_mod, 'validity_severity', val_sev)
        )
        FROM adj
      )
    END
  FROM adj;
$$;

CREATE OR REPLACE FUNCTION public.cts_aspirant_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH ta AS (
    SELECT * FROM public.team_assessments WHERE id = p_assessment_id
  ),
  adj AS (
    SELECT
      public._cts_dampen_trait(deadline_motivation, reliability, response_distortion) AS dm,
      public._cts_dampen_trait(recognition_drive, reliability, response_distortion) AS rd,
      public._cts_dampen_trait(assertiveness, reliability, response_distortion) AS ass,
      public._cts_dampen_trait(independent_spirit, reliability, response_distortion) AS is_val,
      public._cts_dampen_trait(analytical, reliability, response_distortion) AS an,
      public._cts_dampen_trait(compassion, reliability, response_distortion) AS com,
      public._cts_dampen_trait(self_promotion, reliability, response_distortion) AS sp,
      public._cts_dampen_trait(belief_in_others, reliability, response_distortion) AS bo,
      public._cts_dampen_trait(optimism, reliability, response_distortion) AS op,
      public._cts_lss_modifier(
        lss_total_accuracy,
        ((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
          / NULLIF(((CASE WHEN lss_math_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_verbal_speed_seconds IS NULL THEN 0 ELSE 1 END)
                  + (CASE WHEN lss_problem_solving_speed_seconds IS NULL THEN 0 ELSE 1 END)), 0))
      ) AS lss_mod,
      public._cts_validity_severity(reliability, response_distortion) AS val_sev
    FROM ta
  )
  SELECT
    CASE
      WHEN NOT EXISTS (SELECT 1 FROM adj WHERE dm IS NOT NULL) THEN NULL
      ELSE (
        SELECT jsonb_build_object(
          'maintains_high_activity', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op)) * (1 + lss_mod))::int)),
          'handles_rejection', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)) * (1 + lss_mod))::int)),
          'prospects_in_community', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (10.742427) + (-0.004516)*dm + (0.222510)*rd + (0.223384)*ass + (0.000353)*is_val + (-0.111467)*an + (0.106117)*com + (0.110739)*sp + (0.114601)*bo + (0.112072)*op)) * (1 + lss_mod))::int)),
          'dials_cold_calls', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op)) * (1 + lss_mod))::int)),
          'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op)) * (1 + lss_mod))::int)),
          'presents_solutions', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op)) * (1 + lss_mod))::int)),
          'handles_objections', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op)) * (1 + lss_mod))::int)),
          'receives_coaching', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op)) * (1 + lss_mod))::int)),
          'positively_influences_team', GREATEST(0, LEAST(100, ROUND(op * (1 + lss_mod))::int)),
          'has_entrepreneurial_spirit', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (0.052334) + (0.249428)*dm + (0.001218)*rd + (0.254556)*ass + (0.495006)*is_val + (-0.004124)*an + (-0.003403)*com + (0.006260)*sp + (-0.004916)*bo + (-0.003735)*op)) * (1 + lss_mod))::int)),
          'balances_logic_and_emotion_when_hiring', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (32.500522) + (0.001378)*dm + (-0.001370)*rd + (0.329501)*ass + (0.165831)*is_val + (0.162491)*an + (-0.163958)*com + (0.006637)*sp + (-0.168289)*bo + (0.003683)*op)) * (1 + lss_mod))::int)),
          'is_fast_start_oriented', GREATEST(0, LEAST(100, ROUND(GREATEST(0::numeric, LEAST(100::numeric, (-0.195183) + (0.402392)*dm + (0.201362)*rd + (0.202542)*ass + (0.198936)*is_val + (0.000119)*an + (-0.003170)*com + (-0.001383)*sp + (-0.001712)*bo + (0.000563)*op)) * (1 + lss_mod))::int)),
          'competes_for_recognition', GREATEST(0, LEAST(100, ROUND(rd * (1 + lss_mod))::int)),
          '_meta', jsonb_build_object('lss_modifier', lss_mod, 'validity_severity', val_sev)
        )
        FROM adj
      )
    END
  FROM adj;
$$;

COMMENT ON FUNCTION public.cts_sales_competencies_adjusted(uuid) IS
'LSS + validity-adjusted sales competencies. Applies Bob-mechanism ceiling dampening (via reliability + distortion) and LSS multiplier. Consumed by frontend + three-construct verdict. Raw cts_sales_competencies(9 traits) preserved for HireGauge rule engine.';