-- 20260719050000_assessment_layer_computed.sql
-- Assessment layer: add target_role column + normalize weights (75/15/15) + extend v_hiring_candidates.
-- Nature = OS for selected role. Nurture = avg(compassion, belief_in_others, reliability_mapped, distortion_mapped).
-- Drivers = avg(deadline_motivation, recognition_drive, independent_spirit). Composite = weighted avg via aw weights.

-- 1) new column with CHECK
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS assessment_target_role text;

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS hiring_candidates_assessment_target_role_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_assessment_target_role_check
  CHECK (assessment_target_role IS NULL OR assessment_target_role IN (
    'aspirant','sales_outbound','sales_inbound','sales_in_book',
    'retention_reception','retention_escalation','retention_support'
  ));

-- 2) weights: normalize 75/15/15 → 0.7143 / 0.1429 / 0.1429
UPDATE public.hiregauge_layer_composite_weights
   SET weight = 0.7143, updated_at = now()
 WHERE layer='assessment' AND construct='nature';
UPDATE public.hiregauge_layer_composite_weights
   SET weight = 0.1429, updated_at = now()
 WHERE layer='assessment' AND construct='nurture';
UPDATE public.hiregauge_layer_composite_weights
   SET weight = 0.1429, updated_at = now()
 WHERE layer='assessment' AND construct='drivers';

-- 3) extend v_hiring_candidates
CREATE OR REPLACE VIEW public.v_hiring_candidates AS
WITH resume_w AS (
  SELECT max(CASE WHEN construct='nature' THEN weight END) AS w_nat,
         max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
         max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer='resume'
),
assessment_w AS (
  SELECT max(CASE WHEN construct='nature' THEN weight END) AS w_nat,
         max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
         max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer='assessment'
)
SELECT
  hc.id, hc.agency_id, hc.team_member_id, hc.assessment_date, hc.overall_score,
  hc.reliability, hc.response_distortion, hc.deadline_motivation, hc.recognition_drive,
  hc.assertiveness, hc.independent_spirit, hc.analytical, hc.compassion, hc.self_promotion,
  hc.belief_in_others, hc.optimism, hc.lss_math_accuracy, hc.lss_verbal_accuracy,
  hc.lss_problem_solving_accuracy, hc.lss_total_accuracy, hc.lss_total_ideal_min,
  hc.lss_math_speed_seconds, hc.lss_verbal_speed_seconds, hc.lss_problem_solving_speed_seconds,
  hc.pdf_document_id, hc.notes, hc.created_at, hc.updated_at, hc.candidate_name,
  hc.is_team_member, hc.first_name, hc.last_name, hc.email, hc.phone, hc."position",
  hc.status, hc.status_updated_at, hc.resume_document_id, hc.resume_url,
  hc.claude_score, hc.claude_summary, hc.interview_focus,
  hc.va_personal_presence, hc.va_resume_quality, hc.va_honesty, hc.va_hard_work_ethic,
  hc.va_personally_responsible, hc.va_concern_for_others, hc.va_attitude_toward_sales,
  hc.va_willingness_to_own_products, hc.va_motivation_type, hc.va_motivation_level,
  hc.va_recommendation, hc.va_notes, hc.va_scored_at, hc.va_scored_by,
  hc.fi_personal_presence, hc.fi_resume_quality, hc.fi_honesty, hc.fi_hard_work_ethic,
  hc.fi_personally_responsible, hc.fi_concern_for_others, hc.fi_attitude_toward_sales,
  hc.fi_willingness_to_own_products, hc.fi_motivation_type, hc.fi_motivation_level,
  hc.fi_recommendation, hc.fi_notes, hc.fi_scored_at, hc.fi_scored_by,
  hc.rc_notes, hc.rc_completed_at, hc.final_decision, hc.decision_at, hc.decision_notes,
  hc.ego_drive_score, hc.empathy_score, hc.leadership_style,
  hc.cts_wall_duration_seconds, hc.lss_wall_duration_seconds, hc.vct_wall_duration_seconds,
  hc.decline_reason, hc.custom_probes, hc.custom_probes_generated_at,
  hc.candidate_source, hc.careerplug_metadata, hc.applied_at, hc.source_gmail_message_id,
  hc.char_honesty, hc.char_hwe, hc.char_persres, hc.char_concern,
  hc.mot_level, hc.mot_type, hc.mot_attitude_sales, hc.mot_own_products,
  hc.rp_needs, hc.rp_presentation, hc.rp_closing, hc.rp_objection,
  hc.personal_presence, hc.resume_quality, hc.retrospective_verdict_override,
  hc.retrospective_notes, hc.retrospective_scored_at, hc.scorecard_context,
  hc.ref_nature, hc.ref_nurture, hc.ref_drivers,
  hc.resume_extracted_text, hc.resume_analysis, hc.res_rules_fired,
  hc.res_scored_at, hc.res_scored_model, hc.ingestion_metadata,
  hc.cts_invited_at, hc.cts_started_at, hc.cts_completed_at,
  hc.epq_started_at, hc.epq_completed_at, hc.vct_started_at, hc.vct_completed_at,
  hc.lss_started_at, hc.lss_completed_at,
  hc.interview_answers, hc.interview_analysis_text, hc.interview_analysis_at,
  hc.res_autonomy_score, hc.res_autonomy_reason,
  hc.res_leadership_emergence_score, hc.res_leadership_emergence_reason,
  hc.res_interpersonal_substrate_score, hc.res_interpersonal_substrate_reason,
  hc.res_honesty_score, hc.res_honesty_reason,
  hc.res_concern_for_others_score, hc.res_concern_for_others_reason,
  hc.res_hard_work_ethic_score, hc.res_hard_work_ethic_reason,
  hc.res_personal_responsibility_score, hc.res_personal_responsibility_reason,
  hc.res_trajectory_direction_score, hc.res_trajectory_direction_reason,
  hc.res_coherent_pursuit_score, hc.res_coherent_pursuit_reason,
  hc.res_follow_through_score, hc.res_follow_through_reason,
  hc.res_goal_orientation_score, hc.res_goal_orientation_reason,
  round((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0, 2) AS res_nature,
  round((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0, 2) AS res_nurture,
  round((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0, 2) AS res_drivers,
  round(rw.w_nat * ((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0)
      + rw.w_nur * ((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0)
      + rw.w_dr  * ((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0), 2) AS res_composite,
  -- NEW: appended at end (CREATE OR REPLACE VIEW rule)
  hc.assessment_target_role,
  (CASE hc.assessment_target_role
     WHEN 'aspirant'              THEN bf.aspirant_os
     WHEN 'sales_outbound'        THEN bf.sales_outbound_os
     WHEN 'sales_inbound'         THEN bf.sales_inbound_os
     WHEN 'sales_in_book'         THEN bf.sales_in_book_os
     WHEN 'retention_reception'   THEN bf.retention_reception_os
     WHEN 'retention_escalation'  THEN bf.retention_escalation_os
     WHEN 'retention_support'     THEN bf.retention_support_os
     ELSE NULL
   END)::numeric AS assessment_nature,
  round(
    (
      hc.compassion + hc.belief_in_others
      + (CASE hc.reliability
           WHEN 'very_high' THEN 95
           WHEN 'high'      THEN 80
           WHEN 'moderate'  THEN 55
           WHEN 'low'       THEN 25
           WHEN 'very_low'  THEN 10
           ELSE NULL
         END)
      + (CASE hc.response_distortion
           WHEN 'low'       THEN 90
           WHEN 'moderate'  THEN 60
           WHEN 'high'      THEN 30
           ELSE NULL
         END)
    ) / 4.0, 2
  ) AS assessment_nurture,
  round((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit) / 3.0, 2) AS assessment_drivers,
  round(
    aw.w_nat * (CASE hc.assessment_target_role
       WHEN 'aspirant'              THEN bf.aspirant_os
       WHEN 'sales_outbound'        THEN bf.sales_outbound_os
       WHEN 'sales_inbound'         THEN bf.sales_inbound_os
       WHEN 'sales_in_book'         THEN bf.sales_in_book_os
       WHEN 'retention_reception'   THEN bf.retention_reception_os
       WHEN 'retention_escalation'  THEN bf.retention_escalation_os
       WHEN 'retention_support'     THEN bf.retention_support_os
       ELSE NULL
     END)
    + aw.w_nur * (
        (hc.compassion + hc.belief_in_others
         + (CASE hc.reliability
              WHEN 'very_high' THEN 95 WHEN 'high' THEN 80 WHEN 'moderate' THEN 55
              WHEN 'low' THEN 25 WHEN 'very_low' THEN 10 ELSE NULL
            END)
         + (CASE hc.response_distortion
              WHEN 'low' THEN 90 WHEN 'moderate' THEN 60 WHEN 'high' THEN 30
              ELSE NULL
            END)
        ) / 4.0
      )
    + aw.w_dr * ((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit) / 3.0),
    2
  ) AS assessment_composite
FROM public.hiring_candidates hc
CROSS JOIN resume_w rw
CROSS JOIN assessment_w aw
LEFT JOIN LATERAL public.cts_best_fit_role(hc.id) bf ON TRUE;
