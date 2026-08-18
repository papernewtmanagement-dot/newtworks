-- Expose hiring_candidates.screen_analysis (jsonb: per-signal scores +
-- narrative from the Screen layer's stint-5 free-text scoring) through
-- v_hiring_candidates, so the candidate detail page can render small
-- per-item "why this score" tags under the Written Screen answers
-- (Peter directive 2026-08-18). View rebuilt with the same
-- security_invoker=true option and column set as before, plus this one
-- addition -- no other column changed.
CREATE OR REPLACE VIEW public.v_hiring_candidates
WITH (security_invoker = true) AS
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
    va.capability_score AS assessment_capability,
    va.character_score AS assessment_character,
    va.commitment_score AS assessment_commitment,
        CASE
            WHEN va.capability_score IS NULL THEN NULL::numeric
            ELSE va.composite
        END AS assessment_composite,
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
    hc.screen_analysis,
    va.protocol_validity,
    (va.protocol_validity ->> 'v'::text)::numeric AS protocol_validity_v,
    va.protocol_validity ->> 'label'::text AS protocol_validity_label
   FROM hiring_candidates hc
     CROSS JOIN resume_w rw
     CROSS JOIN interview_w iw
     LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
     LEFT JOIN LATERAL _assessment_character_parts(hc.id) ns(concern, work_ethic, personal_responsibility) ON true
     LEFT JOIN LATERAL verdict_assessment(hc.id, NULL::text) va(capability_score, character_score, commitment_score, composite, verdict, protocol_validity) ON true;
