-- Add candidate intake columns for CareerPlug applicant ingest
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS candidate_source text,
  ADD COLUMN IF NOT EXISTS careerplug_metadata jsonb,
  ADD COLUMN IF NOT EXISTS applied_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS source_gmail_message_id text;

-- Comment the columns so future readers know intent
COMMENT ON COLUMN public.team_assessments.candidate_source IS
  'Where this candidate came from: careerplug | indeed_direct | referral | linkedin | walk_in | external_calibration_sample | other';
COMMENT ON COLUMN public.team_assessments.careerplug_metadata IS
  'Raw CareerPlug fields not mapped to first-class columns: prescreen_scores, is_fast_track, source_platform (Indeed/ZipRecruiter/etc), hiring_manager, careerplug_applicant_id, ...';
COMMENT ON COLUMN public.team_assessments.applied_at IS
  'When the candidate submitted their application (from CareerPlug notification email timestamp).';
COMMENT ON COLUMN public.team_assessments.source_gmail_message_id IS
  'Gmail message id of the CareerPlug notification email that created this row. Idempotency key + audit trail.';

-- Index for idempotency lookups by gmail_message_id
CREATE INDEX IF NOT EXISTS idx_team_assessments_source_gmail
  ON public.team_assessments (source_gmail_message_id)
  WHERE source_gmail_message_id IS NOT NULL;

-- Case-insensitive email dedup lookup
CREATE INDEX IF NOT EXISTS idx_team_assessments_email_lower
  ON public.team_assessments (agency_id, lower(email))
  WHERE email IS NOT NULL;
