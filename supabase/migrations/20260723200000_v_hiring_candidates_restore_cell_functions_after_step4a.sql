-- 20260723200000_v_hiring_candidates_restore_cell_functions_after_step4a.sql
--
-- Corrective mig applied in production after step 4a inadvertently DROP+CREATE-VIEW'd
-- v_hiring_candidates with inline math + _legacy_resume_analysis_prose passthrough,
-- clobbering Peter's 2026-07-23 cell-function refactor (mig 20260723190000).
-- Output was byte-identical but architecture regressed. This restores the
-- cell-function-calling shape and drops the dead _legacy passthrough.
--
-- Fresh-clone behavior: mig 20260723080000 (corrected) creates the view with inline
-- math + no _legacy passthrough. Mig 20260723190000 CREATE-OR-REPLACE-VIEWs to swap
-- inline math for cell function calls (same column list, allowed). This corrective
-- mig then no-ops on the already-cell-fn view. Production supabase_migrations table
-- matches fresh-clone supabase_migrations table.

DROP VIEW IF EXISTS public.v_hiring_candidates;

CREATE VIEW public.v_hiring_candidates AS
WITH resume_w AS (
  SELECT
    max(CASE WHEN construct='nature'  THEN weight END) AS w_nat,
    max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
    max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer='resume'
),
assessment_w AS (
  SELECT
    max(CASE WHEN construct='nature'  THEN weight END) AS w_nat,
    max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
    max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer='assessment'
),
interview_w AS (
  SELECT
    max(CASE WHEN construct='nature'  THEN weight END) AS w_nat,
    max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
    max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer='interview'
),
iv_agg AS (
  SELECT hc_1.id AS hc_id,
    avg((((e.val -> 'scores') -> 'nature')  ->> 'score')::numeric)
      FILTER (WHERE (((e.val -> 'scores') -> 'nature')  ->> 'score') IS NOT NULL) AS avg_nature_raw,
    avg((((e.val -> 'scores') -> 'nurture') ->> 'score')::numeric)
      FILTER (WHERE (((e.val -> 'scores') -> 'nurture') ->> 'score') IS NOT NULL) AS avg_nurture_raw,
    avg((((e.val -> 'scores') -> 'drivers') ->> 'score')::numeric)
      FILTER (WHERE (((e.val -> 'scores') -> 'drivers') ->> 'score') IS NOT NULL) AS avg_drivers_raw
  FROM public.hiring_candidates hc_1
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc_1.interview_answers, '{}'::jsonb)) e(k, val) ON true
  GROUP BY hc_1.id
)
SELECT
  hc.id, hc.agency_id, hc.team_member_id, hc.assessment_date, hc.overall_score, hc.reliability,
  hc.response_distortion, hc.deadline_motivation, hc.recognition_drive, hc.assertiveness,
  hc.independent_spirit, hc.analytical, hc.compassion, hc.self_promotion, hc.belief_in_others,
  hc.optimism, hc.lss_math_accuracy, hc.lss_verbal_accuracy, hc.lss_problem_solving_accuracy,
  hc.lss_total_accuracy, hc.lss_total_ideal_min, hc.lss_math_speed_seconds, hc.lss_verbal_speed_seconds,
  hc.lss_problem_solving_speed_seconds, hc.notes, hc.created_at, hc.updated_at, hc.candidate_name,
  hc.is_team_member, hc.first_name, hc.last_name, hc.email, hc.phone, hc."position", hc.status,
  hc.status_updated_at, hc.resume_document_id, hc.resume_url, hc.claude_summary, hc.final_decision,
  hc.decision_at, hc.decision_notes, hc.ego_drive_score, hc.empathy_score, hc.leadership_style,
  hc.cts_wall_duration_seconds, hc.lss_wall_duration_seconds, hc.vct_wall_duration_seconds,
  hc.decline_reason, hc.custom_probes, hc.custom_probes_generated_at, hc.candidate_source,
  hc.careerplug_metadata, hc.applied_at, hc.source_gmail_message_id, hc.char_honesty, hc.char_hwe,
  hc.char_persres, hc.char_concern, hc.resume_quality, hc.retrospective_verdict_override,
  hc.retrospective_notes, hc.ref_nature, hc.ref_nurture, hc.ref_drivers, hc.resume_extracted_text,
  hc.resume_analysis, hc.res_rules_fired, hc.res_scored_at, hc.res_scored_model, hc.ingestion_metadata,
  hc.assessment_timing, hc.ai_analysis, hc.interview_analysis, hc.cts_invited_at, hc.cts_started_at,
  hc.cts_completed_at, hc.epq_started_at, hc.epq_completed_at, hc.vct_started_at, hc.vct_completed_at,
  hc.lss_started_at, hc.lss_completed_at, hc.interview_answers, hc.interview_analysis_text,
  hc.interview_analysis_at, hc.res_autonomy_score, hc.res_autonomy_reason, hc.res_leadership_emergence_score,
  hc.res_leadership_emergence_reason, hc.res_interpersonal_substrate_score, hc.res_interpersonal_substrate_reason,
  hc.res_honesty_score, hc.res_honesty_reason, hc.res_concern_for_others_score, hc.res_concern_for_others_reason,
  hc.res_hard_work_ethic_score, hc.res_hard_work_ethic_reason, hc.res_personal_responsibility_score,
  hc.res_personal_responsibility_reason, hc.res_trajectory_direction_score, hc.res_trajectory_direction_reason,
  hc.res_coherent_pursuit_score, hc.res_coherent_pursuit_reason, hc.res_follow_through_score,
  hc.res_follow_through_reason, hc.res_goal_orientation_score, hc.res_goal_orientation_reason,
  hc.assessment_target_role, hc.iv_verdict, hc.iv_verdict_reason, hc.iv_scored_at,

  -- Resume construct columns: swap to cell functions.
  public.resume_nature(hc.id)  AS res_nature,
  public.resume_nurture(hc.id) AS res_nurture,
  public.resume_drivers(hc.id) AS res_drivers,

  round(
      rw.w_nat * ((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0)
    + rw.w_nur * ((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0)
    + rw.w_dr  * ((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0)
  , 2) AS res_composite,

  public.assessment_nature(hc.id, hc.assessment_target_role) AS assessment_nature,
  public.assessment_nurture(hc.id)                            AS assessment_nurture,
  public.assessment_drivers(hc.id)                            AS assessment_drivers,

  round(
      aw.w_nat * public.assessment_nature(hc.id, hc.assessment_target_role)
    + aw.w_nur * COALESCE(public.cts_assessment_nurture(hc.response_distortion, hc.reliability, hc.compassion, hc.belief_in_others), 0::numeric)
    + aw.w_dr  * COALESCE(public.cts_assessment_drivers(hc.deadline_motivation, hc.recognition_drive, hc.independent_spirit), 0::numeric)
  , 2) AS assessment_composite,

  ns.honesty    AS assessment_nurture_honesty,
  ns.concern    AS assessment_nurture_concern,
  ns.work_ethic AS assessment_nurture_work_ethic,

  public.interview_nature(hc.id)  AS iv_nature,
  public.interview_nurture(hc.id) AS iv_nurture,
  public.interview_drivers(hc.id) AS iv_drivers,

  CASE
    WHEN iv_agg.avg_nature_raw IS NULL AND iv_agg.avg_nurture_raw IS NULL AND iv_agg.avg_drivers_raw IS NULL THEN NULL::numeric
    ELSE round(
        COALESCE(iw.w_nat * (iv_agg.avg_nature_raw  * 10::numeric), 0::numeric)
      + COALESCE(iw.w_nur * (iv_agg.avg_nurture_raw * 10::numeric), 0::numeric)
      + COALESCE(iw.w_dr  * (iv_agg.avg_drivers_raw * 10::numeric), 0::numeric)
    , 2)
  END AS iv_composite,

  hc.resume_avg,
  hc.res_licenses,
  hc.res_languages,
  hc.res_education,
  hc.res_prior_similar_role
FROM public.hiring_candidates hc
CROSS JOIN resume_w rw
CROSS JOIN assessment_w aw
CROSS JOIN interview_w iw
LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
LEFT JOIN LATERAL ( SELECT
    CASE hc.response_distortion
      WHEN 'low'::text      THEN 85
      WHEN 'moderate'::text THEN 50
      WHEN 'high'::text     THEN 15
      ELSE NULL::integer
    END::numeric AS honesty,
    CASE
      WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL
        THEN round(hc.compassion::numeric * 0.7 + hc.belief_in_others::numeric * 0.3, 2)
      WHEN hc.compassion IS NOT NULL THEN hc.compassion::numeric
      WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
      ELSE NULL::numeric
    END AS concern,
    CASE hc.reliability
      WHEN 'high'::text     THEN 85
      WHEN 'moderate'::text THEN 50
      WHEN 'low'::text      THEN 15
      ELSE NULL::integer
    END::numeric AS work_ethic
) ns ON true;

GRANT SELECT ON public.v_hiring_candidates TO anon, authenticated, service_role;
