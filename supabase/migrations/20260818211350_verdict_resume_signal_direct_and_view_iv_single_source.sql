-- 2026-08-18 — Candidate Detail layer-matrix weighting audit, part 1 of 2.
--
-- (a) verdict_resume().composite now IS the canonical resume composite:
--     resume_weighted_composite(resume_analysis), the same signal-direct number the
--     resume auto-decline gate (auto_decline_on_resume_score), the assessment invites
--     (send_v1_assessment_invitations) and the Kanban badge (v_hiring_candidates.res_composite)
--     already use. Until now verdict_resume blended the three resume construct means with
--     the 20/40/40 rows of hiregauge_layer_composite_weights, so the Resume row "Total" on the
--     Candidate Detail matrix (via verdict_overall.resume_score) disagreed with the gate and
--     with the Resume expander on the same page for every scored candidate (292/292 differed,
--     29 carried a different verdict label). Op-rule "Resume screening layer — canonical
--     weights" (2026-08-13) already declared the construct-level 20/40/40 blend superseded;
--     this makes the code match. Construct cells (resume_capability/character/commitment)
--     are unchanged and still feed verdict_overall through the resume column weights.
--
-- (b) v_hiring_candidates: iv_capability / iv_character / iv_commitment / iv_composite now
--     come from ONE verdict_interview() lateral (single-source rule, op-rule "Hiring:
--     single-source construct rule + validity policy (2026-08-14)"). The view previously
--     re-derived iv_composite inline: it did not renormalize when a construct was missing
--     (COALESCE ... 0) and its weights summed to 1.0001, so it could disagree with
--     verdict_interview.composite (0.01 today on the one scored candidate; larger the moment
--     an interview is graded on two constructs). The dead resume_w CTE (unread since
--     res_composite moved to resume_weighted_composite) and the iv_agg CTE go with it.
--     Column list, order and types are unchanged; security_invoker=true re-declared per
--     op-rule "Postgres view recreate gotcha".

CREATE OR REPLACE FUNCTION public.verdict_resume(p_candidate_id uuid)
 RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text)
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
2026-08-18: composite = resume_weighted_composite(resume_analysis) — the ONE resume
composite (signal-direct, weights in hiregauge_resume_signal_weights). Same number as
v_hiring_candidates.res_composite, auto_decline_on_resume_score and the Kanban badge.
The three construct scores are display groupings of the same signals and the resume
layer's cells in the Capability/Character/Commitment matrix; they are NOT blended here
(the old 20/40/40 construct blend was superseded 2026-08-13 and produced a Resume row
Total that disagreed with the gate for 29 candidates). Missing weighted signal ->
resume_weighted_composite returns NULL by design -> verdict 'not_scored'.
*/
DECLARE
  v_ra jsonb;
BEGIN
  SELECT hc.resume_analysis INTO v_ra FROM public.hiring_candidates hc WHERE hc.id = p_candidate_id;

  capability_score := public.resume_capability(p_candidate_id);
  character_score  := public.resume_character(p_candidate_id);
  commitment_score := public.resume_commitment(p_candidate_id);
  composite        := public.resume_weighted_composite(v_ra);
  verdict          := public._hiregauge_layer_verdict('resume', composite);
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.verdict_resume(uuid) IS
  'Resume layer verdict. composite = resume_weighted_composite(resume_analysis) (signal-direct, canonical, same as v_hiring_candidates.res_composite and the resume auto-decline gate). Construct scores are display groupings + matrix cells, not blended into the composite. 2026-08-18.';

CREATE OR REPLACE VIEW public.v_hiring_candidates
WITH (security_invoker=true) AS
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
    vi.capability_score AS iv_capability,
    vi.character_score AS iv_character,
    vi.commitment_score AS iv_commitment,
    vi.composite AS iv_composite,
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
    va.protocol_validity,
    (va.protocol_validity ->> 'v'::text)::numeric AS protocol_validity_v,
    va.protocol_validity ->> 'label'::text AS protocol_validity_label,
    hc.screen_analysis
   FROM hiring_candidates hc
     LEFT JOIN LATERAL _assessment_character_parts(hc.id) ns(concern, work_ethic, personal_responsibility) ON true
     LEFT JOIN LATERAL verdict_assessment(hc.id, NULL::text) va(capability_score, character_score, commitment_score, composite, verdict, protocol_validity) ON true
     LEFT JOIN LATERAL verdict_interview(hc.id) vi(capability_score, character_score, commitment_score, composite, verdict) ON true;

COMMENT ON VIEW public.v_hiring_candidates IS
  'hiring_candidates + read-time layer scores. Resume: construct means + res_composite = resume_weighted_composite (signal-direct). Assessment: every number from ONE verdict_assessment() lateral. Interview: every iv_* number from ONE verdict_interview() lateral (2026-08-18; no inline arithmetic). security_invoker=true — must be re-declared on every recreate.';
