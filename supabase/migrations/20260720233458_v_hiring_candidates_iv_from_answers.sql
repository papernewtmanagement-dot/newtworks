-- 20260720233458_v_hiring_candidates_iv_from_answers.sql
-- Step 1 of interview layer rewire (per session_note 2026-07-20 late).
-- Rebuild v_hiring_candidates so iv_nature / iv_nurture / iv_drivers / iv_composite
-- are computed from interview_answers per-construct rollups instead of stored table columns.
-- Drop the now-unused stored iv_nature / iv_nurture / iv_drivers columns
-- (confirmed 0 writers referencing them via pg_proc search).
-- Keep iv_verdict / iv_verdict_reason / iv_scored_at as stored (still human-set).
--
-- New answer shape (populated in step 2 data migration):
--   interview_answers[key].scores.{nature|nurture|drivers}.{score, verdict, note}
-- Old shape (single construct per answer) will resolve to NULL iv_* until step 2 runs.
--
-- No downstream view/rule depends on v_hiring_candidates (pg_depend audit clean).
-- RPCs hiregauge_three_construct_verdict + hiregauge_three_construct_verdict_by_role
-- read the view via SELECT * INTO v_ta but do not reference iv_* on v_ta today
-- (they derive their v_ni/v_nui/v_di from scorecard cols) — safe. Step 5 rewires those RPCs.

BEGIN;

DROP VIEW IF EXISTS public.v_hiring_candidates;

ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS iv_nature,
  DROP COLUMN IF EXISTS iv_nurture,
  DROP COLUMN IF EXISTS iv_drivers;

CREATE VIEW public.v_hiring_candidates AS
WITH resume_w AS (
  SELECT
    MAX(CASE WHEN construct = 'nature'::text  THEN weight END) AS w_nat,
    MAX(CASE WHEN construct = 'nurture'::text THEN weight END) AS w_nur,
    MAX(CASE WHEN construct = 'drivers'::text THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer = 'resume'::text
),
assessment_w AS (
  SELECT
    MAX(CASE WHEN construct = 'nature'::text  THEN weight END) AS w_nat,
    MAX(CASE WHEN construct = 'nurture'::text THEN weight END) AS w_nur,
    MAX(CASE WHEN construct = 'drivers'::text THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer = 'assessment'::text
),
interview_w AS (
  SELECT
    MAX(CASE WHEN construct = 'nature'::text  THEN weight END) AS w_nat,
    MAX(CASE WHEN construct = 'nurture'::text THEN weight END) AS w_nur,
    MAX(CASE WHEN construct = 'drivers'::text THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer = 'interview'::text
),
iv_agg AS (
  -- Per-candidate averages of per-construct scores (raw 0-10) across all interview_answers keys.
  -- Answers absent for a given construct are excluded via FILTER — an answer with no scores.<c>
  -- key contributes NOTHING to that construct's average (does not depress it to 0).
  SELECT
    hc.id AS hc_id,
    AVG(((e.val -> 'scores'::text) -> 'nature'::text  ->> 'score'::text)::numeric)
      FILTER (WHERE ((e.val -> 'scores'::text) -> 'nature'::text  ->> 'score'::text) IS NOT NULL) AS avg_nature_raw,
    AVG(((e.val -> 'scores'::text) -> 'nurture'::text ->> 'score'::text)::numeric)
      FILTER (WHERE ((e.val -> 'scores'::text) -> 'nurture'::text ->> 'score'::text) IS NOT NULL) AS avg_nurture_raw,
    AVG(((e.val -> 'scores'::text) -> 'drivers'::text ->> 'score'::text)::numeric)
      FILTER (WHERE ((e.val -> 'scores'::text) -> 'drivers'::text ->> 'score'::text) IS NOT NULL) AS avg_drivers_raw
  FROM public.hiring_candidates hc
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc.interview_answers, '{}'::jsonb)) AS e(k, val) ON true
  GROUP BY hc.id
)
SELECT
  hc.id,
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
  hc.pdf_document_id,
  hc.notes,
  hc.created_at,
  hc.updated_at,
  hc.candidate_name,
  hc.is_team_member,
  hc.first_name,
  hc.last_name,
  hc.email,
  hc.phone,
  hc."position",
  hc.status,
  hc.status_updated_at,
  hc.resume_document_id,
  hc.resume_url,
  hc.claude_score,
  hc.claude_summary,
  hc.interview_focus,
  hc.va_personal_presence,
  hc.va_resume_quality,
  hc.va_honesty,
  hc.va_hard_work_ethic,
  hc.va_personally_responsible,
  hc.va_concern_for_others,
  hc.va_attitude_toward_sales,
  hc.va_willingness_to_own_products,
  hc.va_motivation_type,
  hc.va_motivation_level,
  hc.va_recommendation,
  hc.va_notes,
  hc.va_scored_at,
  hc.va_scored_by,
  hc.fi_personal_presence,
  hc.fi_resume_quality,
  hc.fi_honesty,
  hc.fi_hard_work_ethic,
  hc.fi_personally_responsible,
  hc.fi_concern_for_others,
  hc.fi_attitude_toward_sales,
  hc.fi_willingness_to_own_products,
  hc.fi_motivation_type,
  hc.fi_motivation_level,
  hc.fi_recommendation,
  hc.fi_notes,
  hc.fi_scored_at,
  hc.fi_scored_by,
  hc.rc_notes,
  hc.rc_completed_at,
  hc.final_decision,
  hc.decision_at,
  hc.decision_notes,
  hc.ego_drive_score,
  hc.empathy_score,
  hc.leadership_style,
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
  hc.mot_level,
  hc.mot_type,
  hc.mot_attitude_sales,
  hc.mot_own_products,
  hc.rp_needs,
  hc.rp_presentation,
  hc.rp_closing,
  hc.rp_objection,
  hc.personal_presence,
  hc.resume_quality,
  hc.retrospective_verdict_override,
  hc.retrospective_notes,
  hc.retrospective_scored_at,
  hc.scorecard_context,
  hc.ref_nature,
  hc.ref_nurture,
  hc.ref_drivers,
  hc.resume_extracted_text,
  hc.resume_analysis,
  hc.res_rules_fired,
  hc.res_scored_at,
  hc.res_scored_model,
  hc.ingestion_metadata,
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
  hc.res_autonomy_score,
  hc.res_autonomy_reason,
  hc.res_leadership_emergence_score,
  hc.res_leadership_emergence_reason,
  hc.res_interpersonal_substrate_score,
  hc.res_interpersonal_substrate_reason,
  hc.res_honesty_score,
  hc.res_honesty_reason,
  hc.res_concern_for_others_score,
  hc.res_concern_for_others_reason,
  hc.res_hard_work_ethic_score,
  hc.res_hard_work_ethic_reason,
  hc.res_personal_responsibility_score,
  hc.res_personal_responsibility_reason,
  hc.res_trajectory_direction_score,
  hc.res_trajectory_direction_reason,
  hc.res_coherent_pursuit_score,
  hc.res_coherent_pursuit_reason,
  hc.res_follow_through_score,
  hc.res_follow_through_reason,
  hc.res_goal_orientation_score,
  hc.res_goal_orientation_reason,
  hc.assessment_target_role,
  hc.iv_verdict,
  hc.iv_verdict_reason,
  hc.iv_scored_at,

  -- Resume construct rollups (unchanged)
  round((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0, 2) AS res_nature,
  round((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0, 2) AS res_nurture,
  round((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0, 2) AS res_drivers,
  round(
      rw.w_nat * ((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0)
    + rw.w_nur * ((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0)
    + rw.w_dr  * ((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0),
    2
  ) AS res_composite,

  -- Assessment construct rollups (unchanged)
  CASE hc.assessment_target_role
    WHEN 'aspirant'::text             THEN bf.aspirant_os
    WHEN 'sales_outbound'::text       THEN bf.sales_outbound_os
    WHEN 'sales_inbound'::text        THEN bf.sales_inbound_os
    WHEN 'sales_in_book'::text        THEN bf.sales_in_book_os
    WHEN 'retention_reception'::text  THEN bf.retention_reception_os
    WHEN 'retention_escalation'::text THEN bf.retention_escalation_os
    WHEN 'retention_support'::text    THEN bf.retention_support_os
    ELSE NULL::integer
  END::numeric AS assessment_nature,
  ns.nurture AS assessment_nurture,
  round((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit)::numeric / 3.0, 2) AS assessment_drivers,
  round(
      aw.w_nat * (
        CASE hc.assessment_target_role
          WHEN 'aspirant'::text             THEN bf.aspirant_os
          WHEN 'sales_outbound'::text       THEN bf.sales_outbound_os
          WHEN 'sales_inbound'::text        THEN bf.sales_inbound_os
          WHEN 'sales_in_book'::text        THEN bf.sales_in_book_os
          WHEN 'retention_reception'::text  THEN bf.retention_reception_os
          WHEN 'retention_escalation'::text THEN bf.retention_escalation_os
          WHEN 'retention_support'::text    THEN bf.retention_support_os
          ELSE NULL::integer
        END::numeric
      )
    + aw.w_nur * ns.nurture
    + aw.w_dr  * ((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit)::numeric / 3.0),
    2
  ) AS assessment_composite,
  ns.honesty    AS assessment_nurture_honesty,
  ns.concern    AS assessment_nurture_concern,
  ns.work_ethic AS assessment_nurture_work_ethic,

  -- Interview construct rollups (NEW: computed from interview_answers per-construct scores).
  -- Multiply raw 0-10 answer scores by 10 to project onto 0-100 layer scale.
  round(iv_agg.avg_nature_raw  * 10::numeric, 2) AS iv_nature,
  round(iv_agg.avg_nurture_raw * 10::numeric, 2) AS iv_nurture,
  round(iv_agg.avg_drivers_raw * 10::numeric, 2) AS iv_drivers,
  CASE
    WHEN iv_agg.avg_nature_raw IS NULL
     AND iv_agg.avg_nurture_raw IS NULL
     AND iv_agg.avg_drivers_raw IS NULL
    THEN NULL::numeric
    ELSE round(
        COALESCE(iw.w_nat * (iv_agg.avg_nature_raw  * 10::numeric), 0::numeric)
      + COALESCE(iw.w_nur * (iv_agg.avg_nurture_raw * 10::numeric), 0::numeric)
      + COALESCE(iw.w_dr  * (iv_agg.avg_drivers_raw * 10::numeric), 0::numeric),
      2
    )
  END AS iv_composite

FROM public.hiring_candidates hc
CROSS JOIN resume_w rw
CROSS JOIN assessment_w aw
CROSS JOIN interview_w iw
LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
LEFT JOIN LATERAL public.cts_best_fit_role(hc.id) bf(
    best_role, best_role_category, display_label, best_os,
    sales_outbound_os, sales_inbound_os, sales_in_book_os,
    retention_reception_os, retention_escalation_os, retention_support_os,
    aspirant_os
  ) ON true
LEFT JOIN LATERAL (
  SELECT
    x.honesty,
    x.concern,
    x.work_ethic,
    round(
      (COALESCE(x.honesty, 0::numeric) + COALESCE(x.concern, 0::numeric) + COALESCE(x.work_ethic, 0::numeric))
      / NULLIF(
          CASE WHEN x.honesty    IS NOT NULL THEN 1 ELSE 0 END
        + CASE WHEN x.concern    IS NOT NULL THEN 1 ELSE 0 END
        + CASE WHEN x.work_ethic IS NOT NULL THEN 1 ELSE 0 END, 0)::numeric,
    2) AS nurture
  FROM (VALUES (
    CASE hc.response_distortion
      WHEN 'low'::text      THEN 85
      WHEN 'moderate'::text THEN 50
      WHEN 'high'::text     THEN 15
      ELSE NULL::integer
    END::numeric,
    CASE
      WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL
        THEN round(hc.compassion::numeric * 0.7 + hc.belief_in_others::numeric * 0.3, 2)
      WHEN hc.compassion IS NOT NULL       THEN hc.compassion::numeric
      WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
      ELSE NULL::numeric
    END,
    CASE hc.reliability
      WHEN 'high'::text     THEN 85
      WHEN 'moderate'::text THEN 50
      WHEN 'low'::text      THEN 15
      ELSE NULL::integer
    END::numeric
  )) x(honesty, concern, work_ethic)
) ns ON true;

COMMIT;
