-- Add 'assessment_sent' as a valid hiring_candidates.status value, between 'applied' and 'assessed'.
ALTER TABLE public.hiring_candidates DROP CONSTRAINT team_assessments_status_check;
ALTER TABLE public.hiring_candidates ADD CONSTRAINT team_assessments_status_check
  CHECK (status IS NULL OR status = ANY (ARRAY[
    'applied'::text, 'assessment_sent'::text, 'assessed'::text, 'email_screen'::text,
    'interview'::text, 'reference_check'::text, 'offer'::text, 'hired'::text,
    'declined'::text, 'former'::text
  ]));

-- Reclassify: candidates currently 'applied' who have a sent assessment_invitations row
-- and have NOT completed the assessment (assessment_completed_at IS NULL) move to 'assessment_sent'.
-- Verified before running: zero of these 119 rows carry any legacy CTS/manual-cohort
-- completion evidence (ingestion_metadata.cts_source, ingestion_metadata.manual.lss_avg_seconds_per_question,
-- or notes) -- they are genuinely invited-not-completed, not mis-tagged completions.
WITH latest_invite AS (
  SELECT candidate_id, outcome, sent_at,
    row_number() OVER (PARTITION BY candidate_id ORDER BY sent_at DESC) rn
  FROM public.assessment_invitations
)
UPDATE public.hiring_candidates hc
SET status = 'assessment_sent'
FROM latest_invite li
WHERE li.candidate_id = hc.id AND li.rn = 1
  AND hc.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND hc.status = 'applied'
  AND li.outcome = 'sent'
  AND hc.assessment_completed_at IS NULL;
