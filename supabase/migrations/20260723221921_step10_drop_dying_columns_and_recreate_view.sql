-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-23 22:19:21 UTC (ledger name: step10_drop_dying_columns_and_recreate_view) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260723221921.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Step 10 of HireGauge function architecture refactor
-- ==========================================================================
-- (a) Drop hiregauge_three_construct_verdict + _by_role. Both reference
--     v_hiring_candidates in their bodies and are on Step 11's death list;
--     pulling them forward eliminates view dependencies.
-- (b) DROP + CREATE v_hiring_candidates without the 5 dying columns.
--     (CREATE OR REPLACE VIEW cannot remove columns — hard drop required.)
-- (c) DROP COLUMN ego_drive_score, empathy_score, leadership_style,
--     resume_avg, is_team_member from hiring_candidates. All are STORED
--     GENERATED; their generation expressions auto-drop, orphaning
--     cts_ego_drive / cts_empathy / cts_leadership_style for Step 11.
-- ==========================================================================

DROP FUNCTION IF EXISTS public.hiregauge_three_construct_verdict(uuid);
DROP FUNCTION IF EXISTS public.hiregauge_three_construct_verdict_by_role(uuid);

DROP VIEW IF EXISTS public.v_hiring_candidates;

ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS ego_drive_score;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS empathy_score;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS leadership_style;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS resume_avg;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS is_team_member;

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
    hc.res_rules_fired,
    hc.res_scored_at,
    hc.res_scored_model,
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
    resume_nature(hc.id) AS res_nature,
    resume_nurture(hc.id) AS res_nurture,
    resume_drivers(hc.id) AS res_drivers,
    round(rw.w_nat * ((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0) + rw.w_nur * ((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0) + rw.w_dr * ((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0), 2) AS res_composite,
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
        END AS iv_composite,
    hc.res_licenses,
    hc.res_languages,
    hc.res_education,
    hc.res_prior_similar_role
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
