-- Align v_hiring_candidates.assessment_composite with verdict_assessment (20260813215221).
-- The approved validity design applies v exactly once per construct: Capability carries v
-- through role-fit weight renormalization; Character and Commitment carry it via Kelley
-- shrinkage toward 50 (Kelley 1927; Nunnally & Bernstein 1994). The view's composite was
-- still the pre-validity formula (raw chr/com, COALESCE-to-0 instead of weight
-- renormalization), so the Kanban badge and the official layer verdict could disagree for
-- any candidate with protocol validity v < 1.00. This migration changes ONLY the
-- assessment_composite expression to reproduce verdict_assessment's math exactly.
-- assessment_character / assessment_commitment columns intentionally stay RAW construct
-- means -- they sit above raw facet detail rows in CandidateDetail; protocol_validity_v /
-- _label (exposed 20260813215358) explain the difference on-surface.
-- Also: assessment_capability was being invoked twice per row (column + composite);
-- consolidated into one LATERAL, halving role-fit engine cost per row.
-- security_invoker declared IN the view DDL so future CREATE OR REPLACE passes preserve it
-- (the 2026-08-13 recreates silently dropped the ALTER-set flag; restored in
-- v_hiring_candidates_security_invoker_restore).

CREATE OR REPLACE VIEW public.v_hiring_candidates
WITH (security_invoker = true) AS
 WITH resume_w AS (
         SELECT max(CASE WHEN construct = 'capability' THEN weight END) AS w_cap,
                max(CASE WHEN construct = 'character'  THEN weight END) AS w_chr,
                max(CASE WHEN construct = 'commitment' THEN weight END) AS w_com
           FROM hiregauge_layer_composite_weights
          WHERE layer = 'resume'
        ), assessment_w AS (
         SELECT max(CASE WHEN construct = 'capability' THEN weight END) AS w_cap,
                max(CASE WHEN construct = 'character'  THEN weight END) AS w_chr,
                max(CASE WHEN construct = 'commitment' THEN weight END) AS w_com
           FROM hiregauge_layer_composite_weights
          WHERE layer = 'assessment'
        ), interview_w AS (
         SELECT max(CASE WHEN construct = 'capability' THEN weight END) AS w_cap,
                max(CASE WHEN construct = 'character'  THEN weight END) AS w_chr,
                max(CASE WHEN construct = 'commitment' THEN weight END) AS w_com
           FROM hiregauge_layer_composite_weights
          WHERE layer = 'interview'
        ), iv_agg AS (
         SELECT hc_1.id AS hc_id,
            avg((((e.val -> 'scores') -> 'capability') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'capability') ->> 'score') IS NOT NULL) AS avg_capability_raw,
            avg((((e.val -> 'scores') -> 'character') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'character') ->> 'score') IS NOT NULL) AS avg_character_raw,
            avg((((e.val -> 'scores') -> 'commitment') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'commitment') ->> 'score') IS NOT NULL) AS avg_commitment_raw
           FROM hiring_candidates hc_1
             LEFT JOIN LATERAL jsonb_each(COALESCE(hc_1.interview_answers, '{}'::jsonb)) e(k, val) ON true
          GROUP BY hc_1.id
        )
 SELECT hc.id,
    hc.agency_id,
    hc.team_member_id,
    hc.reliability,
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
    ac.a_cap AS assessment_capability,
    ac.a_chr AS assessment_character,
    ac.a_com AS assessment_commitment,
    (SELECT CASE WHEN w.wsum > 0 THEN round(w.tot / w.wsum, 2) END
       FROM ( SELECT
                COALESCE(CASE WHEN ac.a_cap IS NOT NULL THEN aw.w_cap END, 0)
              + COALESCE(CASE WHEN ac.a_chr IS NOT NULL THEN aw.w_chr END, 0)
              + COALESCE(CASE WHEN ac.a_com IS NOT NULL THEN aw.w_com END, 0) AS wsum,
                COALESCE(ac.a_cap * aw.w_cap, 0)
              + COALESCE(round((pv.protocol_validity ->> 'v')::numeric * ac.a_chr
                               + (1 - (pv.protocol_validity ->> 'v')::numeric) * 50, 2) * aw.w_chr, 0)
              + COALESCE(round((pv.protocol_validity ->> 'v')::numeric * ac.a_com
                               + (1 - (pv.protocol_validity ->> 'v')::numeric) * 50, 2) * aw.w_com, 0) AS tot
            ) w) AS assessment_composite,
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
    hc.assessment_exited_at,
    screen_character(hc.id) AS screen_character,
    screen_commitment(hc.id) AS screen_commitment,
    pv.protocol_validity,
    (pv.protocol_validity ->> 'v')::numeric AS protocol_validity_v,
    pv.protocol_validity ->> 'label' AS protocol_validity_label
   FROM hiring_candidates hc
     CROSS JOIN resume_w rw
     CROSS JOIN assessment_w aw
     CROSS JOIN interview_w iw
     LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
     LEFT JOIN LATERAL _assessment_character_parts(hc.id) ns(concern, work_ethic, personal_responsibility) ON true
     LEFT JOIN LATERAL ( SELECT _newtworks_protocol_validity(hc.*) AS protocol_validity) pv ON true
     LEFT JOIN LATERAL ( SELECT assessment_capability(hc.id) AS a_cap,
                                assessment_character(hc.id) AS a_chr,
                                assessment_commitment(hc.id) AS a_com) ac ON true;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_hiring_candidates FROM authenticated;
REVOKE ALL ON public.v_hiring_candidates FROM anon;
