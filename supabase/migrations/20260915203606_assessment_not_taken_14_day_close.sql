-- Peter ruling 2026-09-15: a candidate who never takes the assessment is closed
-- after 14 days. His own completion data sets the line -- of 27 completions, 19
-- landed within 3 days and 26 within 10; the one outlier was day 16. Fourteen
-- days catches 26 of 27 and everything past it is dead.
ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS team_assessments_decline_reason_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT team_assessments_decline_reason_check
  CHECK (decline_reason IS NULL OR decline_reason = ANY (ARRAY[
    'active_applicant'::text,
    'no_show'::text,
    'candidate_withdrew'::text,
    'offer_rescinded'::text,
    'calibration_only'::text,
    'former_team'::text,
    'assessment_score'::text,
    'resume_score'::text,
    'assessment_not_taken'::text,
    'bounced_undeliverable'::text
  ]));

-- A notice row with no send. Lets the Monday batch skip someone deliberately
-- without pretending a letter went out.
ALTER TABLE public.candidate_decline_notices
  ADD COLUMN IF NOT EXISTS suppressed_reason text;

COMMENT ON COLUMN public.candidate_decline_notices.suppressed_reason IS
  'Set when the row exists only to stop the Monday batch from mailing this person. sent_at is the decision time, not a send time, and pg_net_request_id is null.';
