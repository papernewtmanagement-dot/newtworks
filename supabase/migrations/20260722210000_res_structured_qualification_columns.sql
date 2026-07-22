-- 20260722_res_structured_qualification_columns
--
-- Adds structured qualification columns to hiring_candidates so the framework
-- can read licenses, languages, education, and prior similar role directly
-- from data instead of prose in resume_extracted_text.
--
-- Also drops the unused lss_exceptions_confirmed column left over from the
-- 2026-07-22 LSS enforcement attempt that was reverted same session.
--
-- Column shapes:
--   res_licenses jsonb: {pc:bool, lh:bool, ips:bool, series_6/63/7/24:bool, notes:text}
--   res_languages jsonb: {spanish:'bilingual'|'professional'|'conversational'|'none', other_languages:[{language,proficiency}], notes:text}
--   res_education jsonb: {highest_completed:'none'|'ged'|'high_school'|'some_college'|'associates'|'bachelors'|'masters'|'doctorate'|'unknown', institution:text, field:text, year_completed:int, notes:text}
--   res_prior_similar_role jsonb: {highest_relevance:'insurance_direct'|'insurance_adjacent'|'sales_general'|'service_general'|'unrelated'|'none', insurance_tenure_months:int, roles:[{employer,title,category,tenure_months,notes}], success_signals:text[], notes:text}

BEGIN;

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS res_licenses jsonb,
  ADD COLUMN IF NOT EXISTS res_languages jsonb,
  ADD COLUMN IF NOT EXISTS res_education jsonb,
  ADD COLUMN IF NOT EXISTS res_prior_similar_role jsonb;

COMMENT ON COLUMN public.hiring_candidates.res_licenses IS
  'Structured license holdings extracted from resume. Keys: pc, lh, ips, series_6, series_63, series_7, series_24 (all bool). Free-text notes for states/quotes.';
COMMENT ON COLUMN public.hiring_candidates.res_languages IS
  'Structured language capabilities. spanish tier: bilingual/professional/conversational/none. other_languages array optional.';
COMMENT ON COLUMN public.hiring_candidates.res_education IS
  'Structured education. highest_completed enum: none/ged/high_school/some_college/associates/bachelors/masters/doctorate/unknown. Institution + field + year raw values only — reputable is a rule-time judgment, not stored.';
COMMENT ON COLUMN public.hiring_candidates.res_prior_similar_role IS
  'Structured prior role fit. highest_relevance enum from insurance_direct (most similar) to none. success_signals array of specific evidence lines.';

-- Rebuild view with lss_exceptions_confirmed removed, 4 new columns appended.
DROP VIEW IF EXISTS public.v_hiring_candidates;

CREATE VIEW public.v_hiring_candidates AS
 WITH resume_w AS (
         SELECT max(CASE WHEN construct = 'nature' THEN weight END) AS w_nat,
                max(CASE WHEN construct = 'nurture' THEN weight END) AS w_nur,
                max(CASE WHEN construct = 'drivers' THEN weight END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE layer = 'resume'
        ), assessment_w AS (
         SELECT max(CASE WHEN construct = 'nature' THEN weight END) AS w_nat,
                max(CASE WHEN construct = 'nurture' THEN weight END) AS w_nur,
                max(CASE WHEN construct = 'drivers' THEN weight END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE layer = 'assessment'
        ), interview_w AS (
         SELECT max(CASE WHEN construct = 'nature' THEN weight END) AS w_nat,
                max(CASE WHEN construct = 'nurture' THEN weight END) AS w_nur,
                max(CASE WHEN construct = 'drivers' THEN weight END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE layer = 'interview'
        ), iv_agg AS (
         SELECT hc_1.id AS hc_id,
            avg((((e.val -> 'scores') -> 'nature') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'nature') ->> 'score') IS NOT NULL) AS avg_nature_raw,
            avg((((e.val -> 'scores') -> 'nurture') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'nurture') ->> 'score') IS NOT NULL) AS avg_nurture_raw,
            avg((((e.val -> 'scores') -> 'drivers') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'drivers') ->> 'score') IS NOT NULL) AS avg_drivers_raw
           FROM hiring_candidates hc_1
             LEFT JOIN LATERAL jsonb_each(COALESCE(hc_1.interview_answers, '{}'::jsonb)) e(k, val) ON true
          GROUP BY hc_1.id
        )
 SELECT hc.id,
    hc.agency_id, hc.team_member_id, hc.assessment_date, hc.overall_score,
    hc.reliability, hc.response_distortion, hc.deadline_motivation, hc.recognition_drive,
    hc.assertiveness, hc.independent_spirit, hc.analytical, hc.compassion,
    hc.self_promotion, hc.belief_in_others, hc.optimism,
    hc.lss_math_accuracy, hc.lss_verbal_accuracy, hc.lss_problem_solving_accuracy,
    hc.lss_total_accuracy, hc.lss_total_ideal_min,
    hc.lss_math_speed_seconds, hc.lss_verbal_speed_seconds, hc.lss_problem_solving_speed_seconds,
    hc.pdf_document_id, hc.notes, hc.created_at, hc.updated_at,
    hc.candidate_name, hc.is_team_member, hc.first_name, hc.last_name, hc.email, hc.phone,
    hc."position", hc.status, hc.status_updated_at,
    hc.resume_document_id, hc.resume_url,
    hc.claude_score, hc.claude_summary, hc.interview_focus,
    hc.va_personal_presence, hc.va_resume_quality, hc.va_honesty, hc.va_hard_work_ethic,
    hc.va_personally_responsible, hc.va_concern_for_others, hc.va_attitude_toward_sales,
    hc.va_willingness_to_own_products, hc.va_motivation_type, hc.va_motivation_level,
    hc.va_recommendation, hc.va_notes, hc.va_scored_at, hc.va_scored_by,
    hc.fi_personal_presence, hc.fi_resume_quality, hc.fi_honesty, hc.fi_hard_work_ethic,
    hc.fi_personally_responsible, hc.fi_concern_for_others, hc.fi_attitude_toward_sales,
    hc.fi_willingness_to_own_products, hc.fi_motivation_type, hc.fi_motivation_level,
    hc.fi_recommendation, hc.fi_notes, hc.fi_scored_at, hc.fi_scored_by,
    hc.rc_notes, hc.rc_completed_at,
    hc.final_decision, hc.decision_at, hc.decision_notes,
    hc.ego_drive_score, hc.empathy_score, hc.leadership_style,
    hc.cts_wall_duration_seconds, hc.lss_wall_duration_seconds, hc.vct_wall_duration_seconds,
    hc.decline_reason, hc.custom_probes, hc.custom_probes_generated_at,
    hc.candidate_source, hc.careerplug_metadata, hc.applied_at, hc.source_gmail_message_id,
    hc.char_honesty, hc.char_hwe, hc.char_persres, hc.char_concern,
    hc.mot_level, hc.mot_type, hc.mot_attitude_sales, hc.mot_own_products,
    hc.rp_needs, hc.rp_presentation, hc.rp_closing, hc.rp_objection,
    hc.personal_presence, hc.resume_quality,
    hc.retrospective_verdict_override, hc.retrospective_notes, hc.retrospective_scored_at,
    hc.scorecard_context,
    hc.ref_nature, hc.ref_nurture, hc.ref_drivers,
    hc.resume_extracted_text, hc.resume_analysis,
    hc.res_rules_fired, hc.res_scored_at, hc.res_scored_model,
    hc.ingestion_metadata,
    hc.cts_invited_at, hc.cts_started_at, hc.cts_completed_at,
    hc.epq_started_at, hc.epq_completed_at,
    hc.vct_started_at, hc.vct_completed_at,
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
    hc.assessment_target_role,
    hc.iv_verdict, hc.iv_verdict_reason, hc.iv_scored_at,
    round((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0, 2) AS res_nature,
    round((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0, 2) AS res_nurture,
    round((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0, 2) AS res_drivers,
    round(rw.w_nat * ((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0)
        + rw.w_nur * ((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0)
        + rw.w_dr  * ((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0), 2) AS res_composite,
    CASE COALESCE(hc.assessment_target_role, bf.best_role)
        WHEN 'aspirant' THEN bf.aspirant_os
        WHEN 'sales_outbound' THEN bf.sales_outbound_os
        WHEN 'sales_inbound' THEN bf.sales_inbound_os
        WHEN 'sales_in_book' THEN bf.sales_in_book_os
        WHEN 'retention_reception' THEN bf.retention_reception_os
        WHEN 'retention_escalation' THEN bf.retention_escalation_os
        WHEN 'retention_support' THEN bf.retention_support_os
        ELSE NULL::integer
    END::numeric AS assessment_nature,
    ns.nurture AS assessment_nurture,
    round((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit)::numeric / 3.0, 2) AS assessment_drivers,
    round(aw.w_nat *
        CASE COALESCE(hc.assessment_target_role, bf.best_role)
            WHEN 'aspirant' THEN bf.aspirant_os
            WHEN 'sales_outbound' THEN bf.sales_outbound_os
            WHEN 'sales_inbound' THEN bf.sales_inbound_os
            WHEN 'sales_in_book' THEN bf.sales_in_book_os
            WHEN 'retention_reception' THEN bf.retention_reception_os
            WHEN 'retention_escalation' THEN bf.retention_escalation_os
            WHEN 'retention_support' THEN bf.retention_support_os
            ELSE NULL::integer
        END::numeric
        + aw.w_nur * ns.nurture
        + aw.w_dr * ((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit)::numeric / 3.0), 2) AS assessment_composite,
    ns.honesty AS assessment_nurture_honesty,
    ns.concern AS assessment_nurture_concern,
    ns.work_ethic AS assessment_nurture_work_ethic,
    round(iv_agg.avg_nature_raw * 10::numeric, 2) AS iv_nature,
    round(iv_agg.avg_nurture_raw * 10::numeric, 2) AS iv_nurture,
    round(iv_agg.avg_drivers_raw * 10::numeric, 2) AS iv_drivers,
    CASE
        WHEN iv_agg.avg_nature_raw IS NULL AND iv_agg.avg_nurture_raw IS NULL AND iv_agg.avg_drivers_raw IS NULL THEN NULL::numeric
        ELSE round(COALESCE(iw.w_nat * (iv_agg.avg_nature_raw * 10::numeric), 0::numeric)
                 + COALESCE(iw.w_nur * (iv_agg.avg_nurture_raw * 10::numeric), 0::numeric)
                 + COALESCE(iw.w_dr  * (iv_agg.avg_drivers_raw * 10::numeric), 0::numeric), 2)
    END AS iv_composite,
    hc.resume_avg,
    hc.res_licenses,
    hc.res_languages,
    hc.res_education,
    hc.res_prior_similar_role
   FROM hiring_candidates hc
     CROSS JOIN resume_w rw
     CROSS JOIN assessment_w aw
     CROSS JOIN interview_w iw
     LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
     LEFT JOIN LATERAL cts_best_fit_role(hc.id) bf(best_role, best_role_category, display_label, best_os, sales_outbound_os, sales_inbound_os, sales_in_book_os, retention_reception_os, retention_escalation_os, retention_support_os, aspirant_os) ON true
     LEFT JOIN LATERAL ( SELECT x.honesty, x.concern, x.work_ethic,
            round((COALESCE(x.honesty, 0::numeric) + COALESCE(x.concern, 0::numeric) + COALESCE(x.work_ethic, 0::numeric))
                / NULLIF(
                    CASE WHEN x.honesty IS NOT NULL THEN 1 ELSE 0 END
                  + CASE WHEN x.concern IS NOT NULL THEN 1 ELSE 0 END
                  + CASE WHEN x.work_ethic IS NOT NULL THEN 1 ELSE 0 END, 0)::numeric, 2) AS nurture
           FROM ( VALUES (
                        CASE hc.response_distortion
                            WHEN 'low' THEN 85 WHEN 'moderate' THEN 50 WHEN 'high' THEN 15
                            ELSE NULL::integer
                        END::numeric,
                        CASE
                            WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL
                                THEN round(hc.compassion::numeric * 0.7 + hc.belief_in_others::numeric * 0.3, 2)
                            WHEN hc.compassion IS NOT NULL THEN hc.compassion::numeric
                            WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
                            ELSE NULL::numeric
                        END,
                        CASE hc.reliability
                            WHEN 'high' THEN 85 WHEN 'moderate' THEN 50 WHEN 'low' THEN 15
                            ELSE NULL::integer
                        END::numeric)) x(honesty, concern, work_ethic)) ns ON true;

ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS lss_exceptions_confirmed;

COMMIT;
