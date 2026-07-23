-- Step 6: retire assessment_target_role, ref_*, char_*, retrospective_*, resume_quality
-- Peter directive 2026-07-23: target-role concept is dead (framework always uses cts_best_fit_role.best_role).
-- Reference layer never went live in 3+ months (0 rows across 69 candidates). Char cols vestigial. Retrospective + resume_quality stranded.
-- Concurrent-thread commit 55fcfb11 added construct_weights + layer_weights_within_construct meta fields to verdict_overall — preserved in the rewrite.

-- 1. assessment_nature: drop col read, always fall through to cts_best_fit_role.best_role
CREATE OR REPLACE FUNCTION public.assessment_nature(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_bf record;
  v_target text;
  v_result numeric;
BEGIN
  SELECT * INTO v_bf FROM public.cts_best_fit_role(p_candidate_id);
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_target := COALESCE(p_role, v_bf.best_role);
  v_result := CASE v_target
    WHEN 'aspirant'             THEN v_bf.aspirant_os
    WHEN 'sales_outbound'       THEN v_bf.sales_outbound_os
    WHEN 'sales_inbound'        THEN v_bf.sales_inbound_os
    WHEN 'sales_in_book'        THEN v_bf.sales_in_book_os
    WHEN 'retention_reception'  THEN v_bf.retention_reception_os
    WHEN 'retention_escalation' THEN v_bf.retention_escalation_os
    WHEN 'retention_support'    THEN v_bf.retention_support_os
    ELSE NULL
  END;
  RETURN v_result;
END;
$function$;

-- 2. reference_*: always return NULL (keep signatures so verdict_reference stays wired; reference layer dormant until real data source exists)
CREATE OR REPLACE FUNCTION public.reference_nature(p_candidate_id uuid)
 RETURNS numeric LANGUAGE sql STABLE
AS $function$ SELECT NULL::numeric $function$;

CREATE OR REPLACE FUNCTION public.reference_nurture(p_candidate_id uuid)
 RETURNS numeric LANGUAGE sql STABLE
AS $function$ SELECT NULL::numeric $function$;

CREATE OR REPLACE FUNCTION public.reference_drivers(p_candidate_id uuid)
 RETURNS numeric LANGUAGE sql STABLE
AS $function$ SELECT NULL::numeric $function$;

-- 3. _hiregauge_lss_autopass: drop p_target_role param entirely (signature change). New 7-arg signature.
DROP FUNCTION IF EXISTS public._hiregauge_lss_autopass(numeric, text, numeric, text, text, jsonb, jsonb, jsonb);

CREATE OR REPLACE FUNCTION public._hiregauge_lss_autopass(
  p_lss_total numeric,
  p_reliability text,
  p_analytical numeric,
  p_best_fit_role text,
  p_licenses jsonb,
  p_education jsonb,
  p_prior_role jsonb
)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_status text; v_reason text; v_effective_role text;
  v_auto_exc text[] := ARRAY[]::text[];
  v_license_held boolean := false;
  v_reputable_degree boolean := false;
  v_prior_job_success boolean := false;
  v_institution text; v_edu_level text; v_relevance text;
  v_is_very_weak boolean := false;
BEGIN
  IF p_lss_total IS NULL THEN
    RETURN jsonb_build_object('status','not_scored','reason','LSS not yet scored','auto_exceptions','[]'::jsonb);
  END IF;
  IF p_lss_total >= 25 THEN
    RETURN jsonb_build_object('status','not_applicable','reason','LSS total '||p_lss_total||' is at or above the 25 threshold','auto_exceptions','[]'::jsonb);
  END IF;

  v_effective_role := p_best_fit_role;

  IF p_licenses IS NOT NULL THEN
    v_license_held := COALESCE((p_licenses->>'pc')::boolean, false)
                   OR COALESCE((p_licenses->>'lh')::boolean, false)
                   OR COALESCE((p_licenses->>'ips')::boolean, false)
                   OR COALESCE((p_licenses->>'series_6')::boolean, false)
                   OR COALESCE((p_licenses->>'series_63')::boolean, false)
                   OR COALESCE((p_licenses->>'series_7')::boolean, false)
                   OR COALESCE((p_licenses->>'series_24')::boolean, false);
  END IF;
  IF p_education IS NOT NULL THEN
    v_edu_level := p_education->>'highest_completed';
    v_institution := NULLIF(TRIM(COALESCE(p_education->>'institution', '')), '');
    v_reputable_degree := v_edu_level IN ('bachelors','masters','doctorate') AND v_institution IS NOT NULL;
  END IF;
  IF p_prior_role IS NOT NULL THEN
    v_relevance := p_prior_role->>'highest_relevance';
    v_prior_job_success := v_relevance IN ('insurance_direct','insurance_adjacent')
                           AND jsonb_typeof(p_prior_role->'success_signals') = 'array'
                           AND jsonb_array_length(p_prior_role->'success_signals') > 0;
  END IF;

  v_is_very_weak := p_lss_total <= 15 OR (p_lss_total <= 24 AND p_reliability = 'low');

  IF v_is_very_weak THEN
    IF v_reputable_degree THEN v_auto_exc := array_append(v_auto_exc, 'reputable_degree'); END IF;
    IF v_prior_job_success THEN v_auto_exc := array_append(v_auto_exc, 'prior_similar_role_success'); END IF;
    IF v_reputable_degree AND v_prior_job_success THEN
      v_status := 'exception_applies';
      v_reason := 'LSS '||p_lss_total||' with reliability='||p_reliability||'. Very weak bucket but heavy-evidence exceptions BOTH satisfied.';
    ELSE
      v_status := 'decline_lss';
      v_reason := 'LSS '||p_lss_total||' with reliability='||p_reliability||'. Very weak bucket requires BOTH reputable degree AND prior insurance-role success. Not met.';
    END IF;
  ELSE
    IF v_license_held THEN v_auto_exc := array_append(v_auto_exc, 'license_held'); END IF;
    IF v_reputable_degree THEN v_auto_exc := array_append(v_auto_exc, 'reputable_degree'); END IF;
    IF v_prior_job_success THEN v_auto_exc := array_append(v_auto_exc, 'prior_similar_role_success'); END IF;
    IF p_analytical IS NOT NULL AND p_analytical >= 70 THEN
      v_auto_exc := array_append(v_auto_exc, 'analytical_high');
    END IF;
    IF v_effective_role LIKE 'retention%' THEN
      v_auto_exc := array_append(v_auto_exc, 'role_less_sensitive');
    END IF;

    IF array_length(v_auto_exc, 1) IS NOT NULL AND array_length(v_auto_exc, 1) > 0 THEN
      v_status := 'exception_applies';
      v_reason := 'LSS '||p_lss_total||' with reliability='||p_reliability||'. Weak bucket, exceptions found: '||array_to_string(v_auto_exc, ', ')||'. Framework verdict stands.';
    ELSE
      v_status := 'flag_lss_manual';
      v_reason := 'LSS '||p_lss_total||' with reliability='||p_reliability||'. Weak bucket, no exceptions found. Human review before pre-screen.';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'status', v_status, 'reason', v_reason,
    'auto_exceptions', to_jsonb(v_auto_exc),
    'lss_total', p_lss_total, 'reliability', p_reliability, 'effective_role', v_effective_role,
    'bucket', CASE WHEN v_is_very_weak THEN 'very_weak' ELSE 'weak' END,
    'detected', jsonb_build_object(
      'license_held', v_license_held,
      'reputable_degree', v_reputable_degree,
      'prior_job_success', v_prior_job_success,
      'edu_level', v_edu_level, 'institution', v_institution, 'relevance', v_relevance
    )
  );
END;
$function$;

-- 4. verdict_overall: drop v_ta.assessment_target_role reads. Preserve concurrent-thread additions (construct_weights + layer_weights_within_construct).
CREATE OR REPLACE FUNCTION public.verdict_overall(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS TABLE(candidate_id uuid, verdict text, score_0_10 numeric, score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text, resume_score numeric, resume_verdict text, assessment_score numeric, assessment_verdict text, interview_score numeric, interview_verdict text, reference_score numeric, reference_verdict text, nature_score numeric, nurture_score numeric, drivers_score numeric, dimensions_scored integer, confidence text, meta jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_ta record; v_r record; v_a record; v_i record; v_ref record; v_best record;
  v_lss_autopass jsonb; v_lss_status text; v_dims int := 0;
  v_nat_r_w numeric := 0.05; v_nat_a_w numeric := 0.75; v_nat_i_w numeric := 0.15; v_nat_ref_w numeric := 0.05;
  v_nur_r_w numeric := 0.10; v_nur_a_w numeric := 0.15; v_nur_i_w numeric := 0.45; v_nur_ref_w numeric := 0.30;
  v_dr_r_w  numeric := 0.10; v_dr_a_w  numeric := 0.15; v_dr_i_w  numeric := 0.45; v_dr_ref_w  numeric := 0.30;
  v_nat_w numeric := 0.35; v_nur_w numeric := 0.30; v_dr_w numeric := 0.35;
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
  v_lss_autopass := public._hiregauge_lss_autopass(
    v_ta.lss_total_accuracy, v_ta.reliability, v_ta.analytical::numeric,
    v_best.best_role,
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
    'construct_weights', jsonb_build_object(
      'nature',  v_nat_w,
      'nurture', v_nur_w,
      'drivers', v_dr_w),
    'layer_weights_within_construct', jsonb_build_object(
      'nature',  jsonb_build_object('resume', v_nat_r_w, 'assessment', v_nat_a_w, 'interview', v_nat_i_w, 'reference', v_nat_ref_w),
      'nurture', jsonb_build_object('resume', v_nur_r_w, 'assessment', v_nur_a_w, 'interview', v_nur_i_w, 'reference', v_nur_ref_w),
      'drivers', jsonb_build_object('resume', v_dr_r_w,  'assessment', v_dr_a_w,  'interview', v_dr_i_w,  'reference', v_dr_ref_w)),
    'role_used_for_assessment_nature', COALESCE(p_role, v_best.best_role),
    'best_fit_role', v_best.best_role,
    'best_fit_os',   v_best.best_os,
    'lss_autopass',  v_lss_autopass);
  RETURN NEXT;
END;
$function$;

-- 5. DROP VIEW + CREATE VIEW v_hiring_candidates (remove 11 cols from SELECT, simplify assessment_nature call to no-arg)
DROP VIEW public.v_hiring_candidates;
CREATE VIEW public.v_hiring_candidates AS
WITH resume_w AS (
  SELECT max(CASE WHEN construct='nature' THEN weight END) AS w_nat,
         max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
         max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer='resume'
), assessment_w AS (
  SELECT max(CASE WHEN construct='nature' THEN weight END) AS w_nat,
         max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
         max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer='assessment'
), interview_w AS (
  SELECT max(CASE WHEN construct='nature' THEN weight END) AS w_nat,
         max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
         max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer='interview'
), iv_agg AS (
  SELECT hc_1.id AS hc_id,
    avg((((e.val -> 'scores'::text) -> 'nature'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'nature'::text) ->> 'score'::text) IS NOT NULL) AS avg_nature_raw,
    avg((((e.val -> 'scores'::text) -> 'nurture'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'nurture'::text) ->> 'score'::text) IS NOT NULL) AS avg_nurture_raw,
    avg((((e.val -> 'scores'::text) -> 'drivers'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'drivers'::text) ->> 'score'::text) IS NOT NULL) AS avg_drivers_raw
  FROM public.hiring_candidates hc_1
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc_1.interview_answers, '{}'::jsonb)) e(k, val) ON true
  GROUP BY hc_1.id
)
SELECT hc.id, hc.agency_id, hc.team_member_id, hc.assessment_date,
  hc.overall_score, hc.reliability, hc.response_distortion,
  hc.deadline_motivation, hc.recognition_drive, hc.assertiveness, hc.independent_spirit,
  hc.analytical, hc.compassion, hc.self_promotion, hc.belief_in_others, hc.optimism,
  hc.lss_math_accuracy, hc.lss_verbal_accuracy, hc.lss_problem_solving_accuracy,
  hc.lss_total_accuracy, hc.lss_total_ideal_min,
  hc.lss_math_speed_seconds, hc.lss_verbal_speed_seconds, hc.lss_problem_solving_speed_seconds,
  hc.notes, hc.created_at, hc.updated_at,
  hc.candidate_name, hc.first_name, hc.last_name, hc.email, hc.phone,
  hc."position", hc.status, hc.status_updated_at,
  hc.resume_document_id, hc.resume_url, hc.claude_summary,
  hc.final_decision, hc.decision_at, hc.decision_notes,
  hc.cts_wall_duration_seconds, hc.lss_wall_duration_seconds, hc.vct_wall_duration_seconds,
  hc.decline_reason, hc.custom_probes, hc.custom_probes_generated_at,
  hc.candidate_source, hc.careerplug_metadata, hc.applied_at, hc.source_gmail_message_id,
  hc.resume_extracted_text, hc.resume_analysis, hc.ingestion_metadata,
  hc.assessment_timing, hc.ai_analysis, hc.interview_analysis,
  hc.cts_invited_at, hc.cts_started_at, hc.cts_completed_at,
  hc.epq_started_at, hc.epq_completed_at,
  hc.vct_started_at, hc.vct_completed_at,
  hc.lss_started_at, hc.lss_completed_at,
  hc.interview_answers, hc.interview_analysis_text, hc.interview_analysis_at,
  hc.iv_verdict, hc.iv_verdict_reason, hc.iv_scored_at,
  public.resume_nature(hc.id) AS res_nature,
  public.resume_nurture(hc.id) AS res_nurture,
  public.resume_drivers(hc.id) AS res_drivers,
  round(rw.w_nat * COALESCE(public.resume_nature(hc.id), 0::numeric)
      + rw.w_nur * COALESCE(public.resume_nurture(hc.id), 0::numeric)
      + rw.w_dr  * COALESCE(public.resume_drivers(hc.id), 0::numeric), 2) AS res_composite,
  public.assessment_nature(hc.id) AS assessment_nature,
  public.assessment_nurture(hc.id) AS assessment_nurture,
  public.assessment_drivers(hc.id) AS assessment_drivers,
  round(aw.w_nat * public.assessment_nature(hc.id)
      + aw.w_nur * COALESCE(public.assessment_nurture(hc.id), 0::numeric)
      + aw.w_dr  * COALESCE(public.assessment_drivers(hc.id), 0::numeric), 2) AS assessment_composite,
  ns.honesty AS assessment_nurture_honesty,
  ns.concern AS assessment_nurture_concern,
  ns.work_ethic AS assessment_nurture_work_ethic,
  public.interview_nature(hc.id) AS iv_nature,
  public.interview_nurture(hc.id) AS iv_nurture,
  public.interview_drivers(hc.id) AS iv_drivers,
  CASE
    WHEN iv_agg.avg_nature_raw IS NULL AND iv_agg.avg_nurture_raw IS NULL AND iv_agg.avg_drivers_raw IS NULL THEN NULL::numeric
    ELSE round(COALESCE(iw.w_nat * (iv_agg.avg_nature_raw * 10::numeric), 0::numeric)
             + COALESCE(iw.w_nur * (iv_agg.avg_nurture_raw * 10::numeric), 0::numeric)
             + COALESCE(iw.w_dr  * (iv_agg.avg_drivers_raw * 10::numeric), 0::numeric), 2)
  END AS iv_composite
FROM public.hiring_candidates hc
CROSS JOIN resume_w rw
CROSS JOIN assessment_w aw
CROSS JOIN interview_w iw
LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
LEFT JOIN LATERAL (
  SELECT
    CASE hc.response_distortion
      WHEN 'low' THEN 85 WHEN 'moderate' THEN 50 WHEN 'high' THEN 15 ELSE NULL
    END::numeric AS honesty,
    CASE
      WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL
        THEN round(hc.compassion::numeric * 0.7 + hc.belief_in_others::numeric * 0.3, 2)
      WHEN hc.compassion IS NOT NULL THEN hc.compassion::numeric
      WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
      ELSE NULL
    END AS concern,
    CASE hc.reliability
      WHEN 'high' THEN 85 WHEN 'moderate' THEN 50 WHEN 'low' THEN 15 ELSE NULL
    END::numeric AS work_ethic
) ns ON true;

-- 6. DROP the 11 cols
ALTER TABLE public.hiring_candidates
  DROP COLUMN retrospective_verdict_override,
  DROP COLUMN retrospective_notes,
  DROP COLUMN char_honesty,
  DROP COLUMN char_hwe,
  DROP COLUMN char_persres,
  DROP COLUMN char_concern,
  DROP COLUMN resume_quality,
  DROP COLUMN ref_nature,
  DROP COLUMN ref_nurture,
  DROP COLUMN ref_drivers,
  DROP COLUMN assessment_target_role;
