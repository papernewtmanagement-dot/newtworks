-- Interview self-scheduling: booking token + offered/claimed slot tracking
-- on hiring_candidates, plus a new decline_reason value for score-based
-- auto-declines. Peter directive 2026-08-11.

ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS interview_invite_token text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS interview_slots_offered jsonb;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS interview_invite_sent_at timestamptz;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS interview_booking_expires_at timestamptz;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS interview_scheduled_start timestamptz;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS interview_scheduled_end timestamptz;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS interview_calendar_event_id text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS interview_meet_url text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS interview_booked_at timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS uq_hiring_candidates_interview_invite_token
  ON public.hiring_candidates(interview_invite_token)
  WHERE interview_invite_token IS NOT NULL;

-- Extend decline_reason to cover the new auto-decline-on-assessment-score path.
ALTER TABLE public.hiring_candidates DROP CONSTRAINT IF EXISTS team_assessments_decline_reason_check;
ALTER TABLE public.hiring_candidates ADD CONSTRAINT team_assessments_decline_reason_check
  CHECK (decline_reason IS NULL OR decline_reason = ANY (ARRAY[
    'active_applicant'::text, 'offer_rescinded'::text, 'calibration_only'::text,
    'former_team'::text, 'assessment_score'::text
  ]));
