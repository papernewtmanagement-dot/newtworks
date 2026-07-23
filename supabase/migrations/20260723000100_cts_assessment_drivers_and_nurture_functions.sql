-- Wrap the view's inline math for assessment drivers + nurture into two functions.
-- Behavior unchanged; math moved from view derivations into named functions.
-- Verified: 5-candidate verdict smoke test shows zero score drift pre/post.

CREATE OR REPLACE FUNCTION public.cts_assessment_drivers(
  p_deadline_motivation integer,
  p_recognition_drive integer,
  p_independent_spirit integer
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT round((p_deadline_motivation + p_recognition_drive + p_independent_spirit)::numeric / 3.0, 2);
$$;

CREATE OR REPLACE FUNCTION public.cts_assessment_nurture(
  p_response_distortion text,
  p_reliability text,
  p_compassion integer,
  p_belief_in_others integer
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  WITH parts AS (
    SELECT
      CASE p_response_distortion
        WHEN 'low' THEN 85
        WHEN 'moderate' THEN 50
        WHEN 'high' THEN 15
        ELSE NULL
      END::numeric AS honesty,
      CASE
        WHEN p_compassion IS NOT NULL AND p_belief_in_others IS NOT NULL
          THEN round(p_compassion::numeric * 0.7 + p_belief_in_others::numeric * 0.3, 2)
        WHEN p_compassion IS NOT NULL THEN p_compassion::numeric
        WHEN p_belief_in_others IS NOT NULL THEN p_belief_in_others::numeric
        ELSE NULL
      END AS concern,
      CASE p_reliability
        WHEN 'high' THEN 85
        WHEN 'moderate' THEN 50
        WHEN 'low' THEN 15
        ELSE NULL
      END::numeric AS work_ethic
  )
  SELECT round(
    (COALESCE(honesty, 0::numeric) + COALESCE(concern, 0::numeric) + COALESCE(work_ethic, 0::numeric))
    / NULLIF(
        (CASE WHEN honesty    IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN concern    IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN work_ethic IS NOT NULL THEN 1 ELSE 0 END),
      0)::numeric,
    2)
  FROM parts;
$$;

DROP VIEW IF EXISTS public.v_hiring_candidates;

CREATE VIEW public.v_hiring_candidates AS
 WITH resume_w AS (
         SELECT max(CASE WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight ELSE NULL::numeric END) AS w_nat,
            max(CASE WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight ELSE NULL::numeric END) AS w_nur,
            max(CASE WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight ELSE NULL::numeric END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'resume'::text
        ), assessment_w AS (
         SELECT max(CASE WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight ELSE NULL::numeric END) AS w_nat,
            max(CASE WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight ELSE NULL::numeric END) AS w_nur,
            max(CASE WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight ELSE NULL::numeric END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'assessment'::text
        ), interview_w AS (
         SELECT max(CASE WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight ELSE NULL::numeric END) AS w_nat,
            max(CASE WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight ELSE NULL::numeric END) AS w_nur,
            max(CASE WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight ELSE NULL::numeric END) AS w_dr
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
 SELECT hc.id, hc.agency_id, hc.team_member_id, hc.assessment_date, hc.overall_score,
    hc.reliability, hc.response_distortion,
    hc.deadline_motivation, hc.recognition_drive, hc.assertiveness, hc.independent_spirit,
    hc.analytical, hc.compassion, hc.self_promotion, hc.belief_in_others, hc.optimism,
    hc.lss_math_accuracy, hc.lss_verbal_accuracy, hc.lss_problem_solving_accuracy,
    hc.lss_total_accuracy, hc.lss_total_ideal_min,
    hc.lss_math_speed_seconds, hc.lss_verbal_speed_seconds, hc.lss_problem_solving_speed_seconds,
    hc.pdf_document_id, hc.notes, hc.created_at, hc.updated_at,
    hc.candidate_name, hc.is_team_member, hc.first_name, hc.last_name, hc.email, hc.phone,
    hc."position", hc.status, hc.status_updated_at,
    hc.resume_document_id, hc.resume_url, hc.claude_summary,
    hc.rc_notes, hc.rc_completed_at,
    hc.final_decision, hc.decision_at, hc.decision_notes,
    hc.ego_drive_score, hc.empathy_score, hc.leadership_style,
    hc.cts_wall_duration_seconds, hc.lss_wall_duration_seconds, hc.vct_wall_duration_seconds,
    hc.decline_reason, hc.custom_probes, hc.custom_probes_generated_at,
    hc.candidate_source, hc.careerplug_metadata, hc.applied_at, hc.source_gmail_message_id,
    hc.char_honesty, hc.char_hwe, hc.char_persres, hc.char_concern,
    hc.personal_presence, hc.resume_quality,
    hc.retrospective_verdict_override, hc.retrospective_notes,
    hc.ref_nature, hc.ref_nurture, hc.ref_drivers,
    hc.resume_extracted_text, hc.resume_analysis, hc.res_rules_fired,
    hc.res_scored_at, hc.res_scored_model, hc.ingestion_metadata,
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
    hc.assessment_target_role, hc.iv_verdict, hc.iv_verdict_reason, hc.iv_scored_at,
    round((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0, 2) AS res_nature,
    round((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0, 2) AS res_nurture,
    round((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0, 2) AS res_drivers,
    round(rw.w_nat * ((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0) + rw.w_nur * ((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0) + rw.w_dr * ((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0), 2) AS res_composite,
        CASE COALESCE(hc.assessment_target_role, bf.best_role)
            WHEN 'aspirant'::text THEN bf.aspirant_os
            WHEN 'sales_outbound'::text THEN bf.sales_outbound_os
            WHEN 'sales_inbound'::text THEN bf.sales_inbound_os
            WHEN 'sales_in_book'::text THEN bf.sales_in_book_os
            WHEN 'retention_reception'::text THEN bf.retention_reception_os
            WHEN 'retention_escalation'::text THEN bf.retention_escalation_os
            WHEN 'retention_support'::text THEN bf.retention_support_os
            ELSE NULL::integer
        END::numeric AS assessment_nature,
    public.cts_assessment_nurture(hc.response_distortion, hc.reliability, hc.compassion, hc.belief_in_others) AS assessment_nurture,
    public.cts_assessment_drivers(hc.deadline_motivation, hc.recognition_drive, hc.independent_spirit) AS assessment_drivers,
    round(aw.w_nat *
        CASE COALESCE(hc.assessment_target_role, bf.best_role)
            WHEN 'aspirant'::text THEN bf.aspirant_os
            WHEN 'sales_outbound'::text THEN bf.sales_outbound_os
            WHEN 'sales_inbound'::text THEN bf.sales_inbound_os
            WHEN 'sales_in_book'::text THEN bf.sales_in_book_os
            WHEN 'retention_reception'::text THEN bf.retention_reception_os
            WHEN 'retention_escalation'::text THEN bf.retention_escalation_os
            WHEN 'retention_support'::text THEN bf.retention_support_os
            ELSE NULL::integer
        END::numeric
        + aw.w_nur * COALESCE(public.cts_assessment_nurture(hc.response_distortion, hc.reliability, hc.compassion, hc.belief_in_others), 0::numeric)
        + aw.w_dr  * COALESCE(public.cts_assessment_drivers(hc.deadline_motivation, hc.recognition_drive, hc.independent_spirit), 0::numeric)
      , 2) AS assessment_composite,
    ns.honesty AS assessment_nurture_honesty,
    ns.concern AS assessment_nurture_concern,
    ns.work_ethic AS assessment_nurture_work_ethic,
    round(iv_agg.avg_nature_raw * 10::numeric, 2) AS iv_nature,
    round(iv_agg.avg_nurture_raw * 10::numeric, 2) AS iv_nurture,
    round(iv_agg.avg_drivers_raw * 10::numeric, 2) AS iv_drivers,
        CASE
            WHEN iv_agg.avg_nature_raw IS NULL AND iv_agg.avg_nurture_raw IS NULL AND iv_agg.avg_drivers_raw IS NULL THEN NULL::numeric
            ELSE round(COALESCE(iw.w_nat * (iv_agg.avg_nature_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_nur * (iv_agg.avg_nurture_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_dr * (iv_agg.avg_drivers_raw * 10::numeric), 0::numeric), 2)
        END AS iv_composite,
    hc.resume_avg, hc.res_licenses, hc.res_languages, hc.res_education, hc.res_prior_similar_role
   FROM hiring_candidates hc
     CROSS JOIN resume_w rw
     CROSS JOIN assessment_w aw
     CROSS JOIN interview_w iw
     LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
     LEFT JOIN LATERAL cts_best_fit_role(hc.id) bf(best_role, best_role_category, display_label, best_os, sales_outbound_os, sales_inbound_os, sales_in_book_os, retention_reception_os, retention_escalation_os, retention_support_os, aspirant_os) ON true
     LEFT JOIN LATERAL (
       SELECT
         CASE hc.response_distortion
           WHEN 'low'::text THEN 85
           WHEN 'moderate'::text THEN 50
           WHEN 'high'::text THEN 15
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
           WHEN 'high'::text THEN 85
           WHEN 'moderate'::text THEN 50
           WHEN 'low'::text THEN 15
           ELSE NULL::integer
         END::numeric AS work_ethic
     ) ns ON true;
