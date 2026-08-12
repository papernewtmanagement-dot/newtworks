-- Fixes: v_hiring_candidates.res_composite was returning 0.00 (not NULL) for
-- candidates with no resume_analysis at all, because it built the composite
-- inline with COALESCE(...,0) and never checked whether any construct was
-- actually present. 26 candidates were affected — their Kanban card showed
-- "R 0" (reads as a real, bad score) instead of no badge.
--
-- Fix: res_composite now calls the single canonical function
-- public.resume_weighted_composite(resume_analysis) instead of re-deriving
-- the same math inline. That function already returns NULL when no
-- construct has data, and correctly renormalizes when a candidate is
-- missing an entire construct (e.g. only 2 of 3 present) rather than
-- silently imputing 0 for the missing one. This makes res_composite,
-- resume_weighted_composite(), and the two backend consumers
-- (send_v1_assessment_invitations, auto_decline_on_resume_score) all
-- agree on one number, sourced from one place.
--
-- res_capability / res_character / res_commitment sub-construct columns
-- are untouched — they still call resume_capability/character/commitment(id)
-- for the breakdown display and are unaffected by this fix.

CREATE OR REPLACE VIEW public.v_hiring_candidates AS
 WITH resume_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'capability'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_cap,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'character'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_chr,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'commitment'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_com
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'resume'::text
        ), assessment_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'capability'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_cap,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'character'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_chr,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'commitment'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_com
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'assessment'::text
        ), interview_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'capability'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_cap,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'character'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_chr,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'commitment'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_com
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'interview'::text
        ), iv_agg AS (
         SELECT hc_1.id AS hc_id,
            avg((((e.val -> 'scores'::text) -> 'capability'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'capability'::text) ->> 'score'::text) IS NOT NULL) AS avg_capability_raw,
            avg((((e.val -> 'scores'::text) -> 'character'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'character'::text) ->> 'score'::text) IS NOT NULL) AS avg_character_raw,
            avg((((e.val -> 'scores'::text) -> 'commitment'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'commitment'::text) ->> 'score'::text) IS NOT NULL) AS avg_commitment_raw
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
    hc.assertiveness,
    hc.compassion,
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
    hc.decline_reason,
    hc.custom_probes,
    hc.custom_probes_generated_at,
    hc.applied_at,
    hc.resume_extracted_text,
    hc.resume_analysis,
    hc.ingestion_metadata,
    hc.assessment_timing,
    hc.ai_analysis,
    hc.interview_analysis,
    hc.interview_answers,
    resume_capability(hc.id) AS res_capability,
    resume_character(hc.id) AS res_character,
    resume_commitment(hc.id) AS res_commitment,
    resume_weighted_composite(hc.resume_analysis) AS res_composite,
    assessment_capability(hc.id) AS assessment_capability,
    assessment_character(hc.id) AS assessment_character,
    assessment_commitment(hc.id) AS assessment_commitment,
    round(aw.w_cap * assessment_capability(hc.id) + aw.w_chr * COALESCE(assessment_character(hc.id), 0::numeric) + aw.w_com * COALESCE(assessment_commitment(hc.id), 0::numeric), 2) AS assessment_composite,
    ns.concern AS assessment_character_concern,
    ns.work_ethic AS assessment_character_work_ethic,
    ns.personal_responsibility AS assessment_character_personal_resp,
    interview_capability(hc.id) AS iv_capability,
    interview_character(hc.id) AS iv_character,
    interview_commitment(hc.id) AS iv_commitment,
        CASE
            WHEN iv_agg.avg_capability_raw IS NULL AND iv_agg.avg_character_raw IS NULL AND iv_agg.avg_commitment_raw IS NULL THEN NULL::numeric
            ELSE round(COALESCE(iw.w_cap * (iv_agg.avg_capability_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_chr * (iv_agg.avg_character_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_com * (iv_agg.avg_commitment_raw * 10::numeric), 0::numeric), 2)
        END AS iv_composite,
    hc.assessment_source,
    hc.gma_pattern_accuracy,
    hc.gma_numerical_accuracy,
    hc.gma_deductive_accuracy,
    hc.gma_verbal_accuracy,
    hc.gma_total_accuracy,
    hc.gma_pattern_speed_seconds,
    hc.gma_numerical_speed_seconds,
    hc.gma_deductive_speed_seconds,
    hc.gma_verbal_speed_seconds,
    hc.sjt_score,
    hc.sjt_topic_detail,
    hc.reliability_detail,
    hc.impression_management,
    hc.impression_management_band,
    hc.impression_management_detail,
    hc.assessment_started_at,
    hc.assessment_completed_at,
    hc.assessment_exit_gate,
    hc.assessment_exit_detail,
    hc.assessment_exited_at
   FROM hiring_candidates hc
     CROSS JOIN resume_w rw
     CROSS JOIN assessment_w aw
     CROSS JOIN interview_w iw
     LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
     LEFT JOIN LATERAL _assessment_character_parts(hc.id) ns(concern, work_ethic, personal_responsibility) ON true;
