-- Meet & Greet scheduling.
--
-- The interview stage lets the candidate pick their own time from slots the
-- scheduler computed. The meet & greet does NOT work that way: Peter picks the
-- time himself (his ruling, 2026-08-21), because the meeting has to fit two or
-- three of the team as well as him. So there is no token, no offered-slot list
-- and no booking window here -- just the one time he chose, the event that was
-- created for it, and who was on it.

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS meet_greet_scheduled_start   timestamptz,
  ADD COLUMN IF NOT EXISTS meet_greet_scheduled_end     timestamptz,
  ADD COLUMN IF NOT EXISTS meet_greet_calendar_event_id text,
  ADD COLUMN IF NOT EXISTS meet_greet_meet_url          text,
  ADD COLUMN IF NOT EXISTS meet_greet_location          text,
  ADD COLUMN IF NOT EXISTS meet_greet_attendees         jsonb,
  ADD COLUMN IF NOT EXISTS meet_greet_invited_at        timestamptz;

COMMENT ON COLUMN public.hiring_candidates.meet_greet_meet_url IS
  'Google Meet link, only when the meet & greet was set up as a video call. Null for in-office meetings.';
COMMENT ON COLUMN public.hiring_candidates.meet_greet_location IS
  'Where the meet & greet happens: the office address, or "Google Meet" for a video call.';
COMMENT ON COLUMN public.hiring_candidates.meet_greet_attendees IS
  'Array of {team_id, name, email} for the teammates invited alongside the candidate. Kept so the record of who met the candidate survives later team changes.';

-- Expose the new columns on the read view the candidate detail page uses, so a
-- meet & greet that is already on the calendar shows up on the page instead of
-- looking unscheduled. Columns are appended at the end of the select list --
-- CREATE OR REPLACE VIEW cannot reorder or retype the existing ones.
CREATE OR REPLACE VIEW public.v_hiring_candidates AS
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
    hc.screen_analysis,
    hc.meet_greet_scheduled_start,
    hc.meet_greet_scheduled_end,
    hc.meet_greet_calendar_event_id,
    hc.meet_greet_meet_url,
    hc.meet_greet_location,
    hc.meet_greet_attendees,
    hc.meet_greet_invited_at
   FROM hiring_candidates hc
     LEFT JOIN LATERAL _assessment_character_parts(hc.id) ns(concern, work_ethic, personal_responsibility) ON true
     LEFT JOIN LATERAL verdict_assessment(hc.id, NULL::text) va(capability_score, character_score, commitment_score, composite, verdict, protocol_validity) ON true
     LEFT JOIN LATERAL verdict_interview(hc.id) vi(capability_score, character_score, commitment_score, composite, verdict) ON true;
