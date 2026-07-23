-- Step 4d — hiring_candidates flat-column drop + jsonb-only fns + view rebuild
--
-- Superseded scope: parallel-thread Step 10 already dropped hiregauge_three_construct_verdict + _by_role,
-- dropped resume_avg, and rebuilt v_hiring_candidates. This migration completes the remaining flat-col drops
-- and strips fallback branches from 4 fns.
--
-- Drops from public.hiring_candidates (30 cols):
--   - 11 res_*_score numeric
--   - 11 res_*_reason text
--   - res_rules_fired, res_scored_at, res_scored_model
--   - res_licenses, res_languages, res_education, res_prior_similar_role
--   - _legacy_resume_analysis_prose (backfilled into resume_analysis->>'narrative' in step 4a)
--
-- Recreates public.v_hiring_candidates without those columns; res_composite computed from cell fns.
--
-- Byte-identical output verified against 5 canonical candidates (Jason Villa, Maximus Moody,
-- Carla Sanders, Katie Barraco, Allan Piedrabuena).

-- ============================================================
-- 1. Rewrite 4 fns: jsonb-only, no flat-col fallback
-- ============================================================

CREATE OR REPLACE FUNCTION public.resume_nature(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  WITH s AS (
    SELECT
      (hc.resume_analysis->'signals'->'autonomy'->>'score')::numeric                AS autonomy,
      (hc.resume_analysis->'signals'->'leadership_emergence'->>'score')::numeric    AS leadership_emergence,
      (hc.resume_analysis->'signals'->'interpersonal_substrate'->>'score')::numeric AS interpersonal_substrate
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round((autonomy + leadership_emergence + interpersonal_substrate) / 3.0, 2)
  FROM s
  WHERE autonomy IS NOT NULL AND leadership_emergence IS NOT NULL AND interpersonal_substrate IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.resume_nurture(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  WITH s AS (
    SELECT
      (hc.resume_analysis->'signals'->'honesty'->>'score')::numeric                 AS honesty,
      (hc.resume_analysis->'signals'->'concern_for_others'->>'score')::numeric      AS concern_for_others,
      (hc.resume_analysis->'signals'->'hard_work_ethic'->>'score')::numeric         AS hard_work_ethic,
      (hc.resume_analysis->'signals'->'personal_responsibility'->>'score')::numeric AS personal_responsibility
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round((honesty + concern_for_others + hard_work_ethic + personal_responsibility) / 4.0, 2)
  FROM s
  WHERE honesty IS NOT NULL AND concern_for_others IS NOT NULL AND hard_work_ethic IS NOT NULL AND personal_responsibility IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.resume_drivers(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  WITH s AS (
    SELECT
      (hc.resume_analysis->'signals'->'trajectory_direction'->>'score')::numeric AS trajectory_direction,
      (hc.resume_analysis->'signals'->'coherent_pursuit'->>'score')::numeric     AS coherent_pursuit,
      (hc.resume_analysis->'signals'->'follow_through'->>'score')::numeric       AS follow_through,
      (hc.resume_analysis->'signals'->'goal_orientation'->>'score')::numeric     AS goal_orientation
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round((trajectory_direction + coherent_pursuit + follow_through + goal_orientation) / 4.0, 2)
  FROM s
  WHERE trajectory_direction IS NOT NULL AND coherent_pursuit IS NOT NULL AND follow_through IS NOT NULL AND goal_orientation IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.verdict_overall(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS TABLE(candidate_id uuid, verdict text, score_0_10 numeric, score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text, resume_score numeric, resume_verdict text, assessment_score numeric, assessment_verdict text, interview_score numeric, interview_verdict text, reference_score numeric, reference_verdict text, nature_score numeric, nurture_score numeric, drivers_score numeric, dimensions_scored integer, confidence text, meta jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_ta                  record;
  v_r                   record;
  v_a                   record;
  v_i                   record;
  v_ref                 record;
  v_best                record;
  v_lss_autopass        jsonb;
  v_lss_status          text;
  v_dims                int := 0;

  v_nat_r_w  numeric := 0.05; v_nat_a_w  numeric := 0.75; v_nat_i_w  numeric := 0.15; v_nat_ref_w  numeric := 0.05;
  v_nur_r_w  numeric := 0.10; v_nur_a_w  numeric := 0.15; v_nur_i_w  numeric := 0.45; v_nur_ref_w  numeric := 0.30;
  v_dr_r_w   numeric := 0.10; v_dr_a_w   numeric := 0.15; v_dr_i_w   numeric := 0.45; v_dr_ref_w   numeric := 0.30;

  v_nat_w   numeric := 0.35; v_nur_w   numeric := 0.30; v_dr_w   numeric := 0.35;

  v_wsum numeric; v_sum numeric;
BEGIN
  SELECT * INTO v_ta FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT * INTO v_r    FROM public.verdict_resume(p_candidate_id);
  SELECT * INTO v_a    FROM public.verdict_assessment(p_candidate_id, p_role);
  SELECT * INTO v_i    FROM public.verdict_interview(p_candidate_id);
  SELECT * INTO v_ref  FROM public.verdict_reference(p_candidate_id);
  SELECT * INTO v_best FROM public.cts_best_fit_role(p_candidate_id);

  IF v_r.nature IS NOT NULL OR v_r.nurture IS NOT NULL OR v_r.drivers IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.nature   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.nurture  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.drivers  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.nature   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.nurture  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.drivers  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.nature IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.nurture IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.drivers IS NOT NULL THEN v_dims := v_dims + 1; END IF;

  v_wsum := 0; v_sum := 0;
  IF v_r.nature   IS NOT NULL THEN v_sum := v_sum + v_r.nature   * v_nat_r_w;   v_wsum := v_wsum + v_nat_r_w;   END IF;
  IF v_a.nature   IS NOT NULL THEN v_sum := v_sum + v_a.nature   * v_nat_a_w;   v_wsum := v_wsum + v_nat_a_w;   END IF;
  IF v_i.nature   IS NOT NULL THEN v_sum := v_sum + v_i.nature   * v_nat_i_w;   v_wsum := v_wsum + v_nat_i_w;   END IF;
  IF v_ref.nature IS NOT NULL THEN v_sum := v_sum + v_ref.nature * v_nat_ref_w; v_wsum := v_wsum + v_nat_ref_w; END IF;
  nature_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF v_r.nurture   IS NOT NULL THEN v_sum := v_sum + v_r.nurture   * v_nur_r_w;   v_wsum := v_wsum + v_nur_r_w;   END IF;
  IF v_a.nurture   IS NOT NULL THEN v_sum := v_sum + v_a.nurture   * v_nur_a_w;   v_wsum := v_wsum + v_nur_a_w;   END IF;
  IF v_i.nurture   IS NOT NULL THEN v_sum := v_sum + v_i.nurture   * v_nur_i_w;   v_wsum := v_wsum + v_nur_i_w;   END IF;
  IF v_ref.nurture IS NOT NULL THEN v_sum := v_sum + v_ref.nurture * v_nur_ref_w; v_wsum := v_wsum + v_nur_ref_w; END IF;
  nurture_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF v_r.drivers   IS NOT NULL THEN v_sum := v_sum + v_r.drivers   * v_dr_r_w;   v_wsum := v_wsum + v_dr_r_w;   END IF;
  IF v_a.drivers   IS NOT NULL THEN v_sum := v_sum + v_a.drivers   * v_dr_a_w;   v_wsum := v_wsum + v_dr_a_w;   END IF;
  IF v_i.drivers   IS NOT NULL THEN v_sum := v_sum + v_i.drivers   * v_dr_i_w;   v_wsum := v_wsum + v_dr_i_w;   END IF;
  IF v_ref.drivers IS NOT NULL THEN v_sum := v_sum + v_ref.drivers * v_dr_ref_w; v_wsum := v_wsum + v_dr_ref_w; END IF;
  drivers_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF nature_score  IS NOT NULL THEN v_sum := v_sum + nature_score  * v_nat_w; v_wsum := v_wsum + v_nat_w; END IF;
  IF nurture_score IS NOT NULL THEN v_sum := v_sum + nurture_score * v_nur_w; v_wsum := v_wsum + v_nur_w; END IF;
  IF drivers_score IS NOT NULL THEN v_sum := v_sum + drivers_score * v_dr_w;  v_wsum := v_wsum + v_dr_w;  END IF;
  score_0_10 := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  resume_score     := v_r.composite;    resume_verdict     := v_r.verdict;
  assessment_score := v_a.composite;    assessment_verdict := v_a.verdict;
  interview_score  := v_i.composite;    interview_verdict  := v_i.verdict;
  reference_score  := v_ref.composite;  reference_verdict  := v_ref.verdict;

  -- STEP 4D: qualifications sourced from resume_analysis.qualifications only (flat-col fallback removed)
  v_lss_autopass := public._hiregauge_lss_autopass(
    v_ta.lss_total_accuracy, v_ta.reliability, v_ta.analytical::numeric,
    v_ta.assessment_target_role, v_best.best_role,
    v_ta.resume_analysis->'qualifications'->'licenses',
    v_ta.resume_analysis->'qualifications'->'education',
    v_ta.resume_analysis->'qualifications'->'prior_similar_role'
  );
  v_lss_status := v_lss_autopass->>'status';

  verdict := CASE
    WHEN score_0_10 IS NULL THEN 'insufficient_data'
    WHEN v_lss_status = 'decline_lss' THEN 'decline_lss'
    ELSE (CASE public._hiregauge_layer_verdict('framework', score_0_10)
            WHEN 'pass' THEN 'hire'
            WHEN 'consider' THEN 'consider'
            ELSE 'decline'
          END)
  END;

  score_hire_at_70 := CASE WHEN score_0_10 IS NULL THEN 'n/a' WHEN score_0_10 >= 70 THEN 'hire' WHEN score_0_10 >= 55 THEN 'consider' ELSE 'decline' END;
  score_hire_at_75 := CASE WHEN score_0_10 IS NULL THEN 'n/a' WHEN score_0_10 >= 75 THEN 'hire' WHEN score_0_10 >= 60 THEN 'consider' ELSE 'decline' END;
  score_hire_at_80 := CASE WHEN score_0_10 IS NULL THEN 'n/a' WHEN score_0_10 >= 80 THEN 'hire' WHEN score_0_10 >= 65 THEN 'consider' ELSE 'decline' END;

  candidate_id := p_candidate_id;
  dimensions_scored := v_dims;
  confidence := CASE WHEN v_dims >= 9 THEN 'high' WHEN v_dims >= 5 THEN 'medium' ELSE 'low' END;

  meta := jsonb_build_object(
    'matrix', jsonb_build_object(
      'nature',  jsonb_build_object('resume', v_r.nature,  'assessment', v_a.nature,  'interview', v_i.nature,  'reference', v_ref.nature),
      'nurture', jsonb_build_object('resume', v_r.nurture, 'assessment', v_a.nurture, 'interview', v_i.nurture, 'reference', v_ref.nurture),
      'drivers', jsonb_build_object('resume', v_r.drivers, 'assessment', v_a.drivers, 'interview', v_i.drivers, 'reference', v_ref.drivers)),
    'role_used_for_assessment_nature', COALESCE(p_role, v_ta.assessment_target_role, v_best.best_role),
    'best_fit_role', v_best.best_role,
    'best_fit_os',   v_best.best_os,
    'lss_autopass',  v_lss_autopass);

  RETURN NEXT;
END;
$function$;

-- ============================================================
-- 2. Drop view + drop columns + rebuild view
-- ============================================================

DROP VIEW IF EXISTS public.v_hiring_candidates;

ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS res_autonomy_score,
  DROP COLUMN IF EXISTS res_autonomy_reason,
  DROP COLUMN IF EXISTS res_leadership_emergence_score,
  DROP COLUMN IF EXISTS res_leadership_emergence_reason,
  DROP COLUMN IF EXISTS res_interpersonal_substrate_score,
  DROP COLUMN IF EXISTS res_interpersonal_substrate_reason,
  DROP COLUMN IF EXISTS res_honesty_score,
  DROP COLUMN IF EXISTS res_honesty_reason,
  DROP COLUMN IF EXISTS res_concern_for_others_score,
  DROP COLUMN IF EXISTS res_concern_for_others_reason,
  DROP COLUMN IF EXISTS res_hard_work_ethic_score,
  DROP COLUMN IF EXISTS res_hard_work_ethic_reason,
  DROP COLUMN IF EXISTS res_personal_responsibility_score,
  DROP COLUMN IF EXISTS res_personal_responsibility_reason,
  DROP COLUMN IF EXISTS res_trajectory_direction_score,
  DROP COLUMN IF EXISTS res_trajectory_direction_reason,
  DROP COLUMN IF EXISTS res_coherent_pursuit_score,
  DROP COLUMN IF EXISTS res_coherent_pursuit_reason,
  DROP COLUMN IF EXISTS res_follow_through_score,
  DROP COLUMN IF EXISTS res_follow_through_reason,
  DROP COLUMN IF EXISTS res_goal_orientation_score,
  DROP COLUMN IF EXISTS res_goal_orientation_reason,
  DROP COLUMN IF EXISTS res_rules_fired,
  DROP COLUMN IF EXISTS res_scored_at,
  DROP COLUMN IF EXISTS res_scored_model,
  DROP COLUMN IF EXISTS res_licenses,
  DROP COLUMN IF EXISTS res_languages,
  DROP COLUMN IF EXISTS res_education,
  DROP COLUMN IF EXISTS res_prior_similar_role,
  DROP COLUMN IF EXISTS _legacy_resume_analysis_prose;

CREATE VIEW public.v_hiring_candidates AS
 WITH resume_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nat,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nur,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'resume'::text
        ), assessment_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nat,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nur,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'assessment'::text
        ), interview_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nat,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nur,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'interview'::text
        ), iv_agg AS (
         SELECT hc_1.id AS hc_id,
            avg((((e.val -> 'scores'::text) -> 'nature'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'nature'::text) ->> 'score'::text) IS NOT NULL) AS avg_nature_raw,
            avg((((e.val -> 'scores'::text) -> 'nurture'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'nurture'::text) ->> 'score'::text) IS NOT NULL) AS avg_nurture_raw,
            avg((((e.val -> 'scores'::text) -> 'drivers'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'drivers'::text) ->> 'score'::text) IS NOT NULL) AS avg_drivers_raw
           FROM hiring_candidates hc_1
             LEFT JOIN LATERAL jsonb_each(COALESCE(hc_1.interview_answers, '{}'::jsonb)) e(k, val) ON true
          GROUP BY hc_1.id
        )
 SELECT hc.id,
    hc.agency_id,
    hc.team_member_id,
    hc.assessment_date,
    hc.overall_score,
    hc.reliability,
    hc.response_distortion,
    hc.deadline_motivation,
    hc.recognition_drive,
    hc.assertiveness,
    hc.independent_spirit,
    hc.analytical,
    hc.compassion,
    hc.self_promotion,
    hc.belief_in_others,
    hc.optimism,
    hc.lss_math_accuracy,
    hc.lss_verbal_accuracy,
    hc.lss_problem_solving_accuracy,
    hc.lss_total_accuracy,
    hc.lss_total_ideal_min,
    hc.lss_math_speed_seconds,
    hc.lss_verbal_speed_seconds,
    hc.lss_problem_solving_speed_seconds,
    hc.notes,
    hc.created_at,
    hc.updated_at,
    hc.candidate_name,
    hc.first_name,
    hc.last_name,
    hc.email,
    hc.phone,
    hc."position",
    hc.status,
    hc.status_updated_at,
    hc.resume_document_id,
    hc.resume_url,
    hc.claude_summary,
    hc.final_decision,
    hc.decision_at,
    hc.decision_notes,
    hc.cts_wall_duration_seconds,
    hc.lss_wall_duration_seconds,
    hc.vct_wall_duration_seconds,
    hc.decline_reason,
    hc.custom_probes,
    hc.custom_probes_generated_at,
    hc.candidate_source,
    hc.careerplug_metadata,
    hc.applied_at,
    hc.source_gmail_message_id,
    hc.char_honesty,
    hc.char_hwe,
    hc.char_persres,
    hc.char_concern,
    hc.resume_quality,
    hc.retrospective_verdict_override,
    hc.retrospective_notes,
    hc.ref_nature,
    hc.ref_nurture,
    hc.ref_drivers,
    hc.resume_extracted_text,
    hc.resume_analysis,
    hc.ingestion_metadata,
    hc.assessment_timing,
    hc.ai_analysis,
    hc.interview_analysis,
    hc.cts_invited_at,
    hc.cts_started_at,
    hc.cts_completed_at,
    hc.epq_started_at,
    hc.epq_completed_at,
    hc.vct_started_at,
    hc.vct_completed_at,
    hc.lss_started_at,
    hc.lss_completed_at,
    hc.interview_answers,
    hc.interview_analysis_text,
    hc.interview_analysis_at,
    hc.assessment_target_role,
    hc.iv_verdict,
    hc.iv_verdict_reason,
    hc.iv_scored_at,
    resume_nature(hc.id) AS res_nature,
    resume_nurture(hc.id) AS res_nurture,
    resume_drivers(hc.id) AS res_drivers,
    round(rw.w_nat * COALESCE(resume_nature(hc.id), 0::numeric) + rw.w_nur * COALESCE(resume_nurture(hc.id), 0::numeric) + rw.w_dr * COALESCE(resume_drivers(hc.id), 0::numeric), 2) AS res_composite,
    assessment_nature(hc.id, hc.assessment_target_role) AS assessment_nature,
    assessment_nurture(hc.id) AS assessment_nurture,
    assessment_drivers(hc.id) AS assessment_drivers,
    round(aw.w_nat * assessment_nature(hc.id, hc.assessment_target_role) + aw.w_nur * COALESCE(assessment_nurture(hc.id), 0::numeric) + aw.w_dr * COALESCE(assessment_drivers(hc.id), 0::numeric), 2) AS assessment_composite,
    ns.honesty AS assessment_nurture_honesty,
    ns.concern AS assessment_nurture_concern,
    ns.work_ethic AS assessment_nurture_work_ethic,
    interview_nature(hc.id) AS iv_nature,
    interview_nurture(hc.id) AS iv_nurture,
    interview_drivers(hc.id) AS iv_drivers,
        CASE
            WHEN iv_agg.avg_nature_raw IS NULL AND iv_agg.avg_nurture_raw IS NULL AND iv_agg.avg_drivers_raw IS NULL THEN NULL::numeric
            ELSE round(COALESCE(iw.w_nat * (iv_agg.avg_nature_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_nur * (iv_agg.avg_nurture_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_dr * (iv_agg.avg_drivers_raw * 10::numeric), 0::numeric), 2)
        END AS iv_composite
   FROM hiring_candidates hc
     CROSS JOIN resume_w rw
     CROSS JOIN assessment_w aw
     CROSS JOIN interview_w iw
     LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
     LEFT JOIN LATERAL ( SELECT
                CASE hc.response_distortion
                    WHEN 'low'::text THEN 85
                    WHEN 'moderate'::text THEN 50
                    WHEN 'high'::text THEN 15
                    ELSE NULL::integer
                END::numeric AS honesty,
                CASE
                    WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL THEN round(hc.compassion::numeric * 0.7 + hc.belief_in_others::numeric * 0.3, 2)
                    WHEN hc.compassion IS NOT NULL THEN hc.compassion::numeric
                    WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
                    ELSE NULL::numeric
                END AS concern,
                CASE hc.reliability
                    WHEN 'high'::text THEN 85
                    WHEN 'moderate'::text THEN 50
                    WHEN 'low'::text THEN 15
                    ELSE NULL::integer
                END::numeric AS work_ethic) ns ON true;
