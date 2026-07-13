-- 20260713214500_team_assessments_declined_status.sql
-- Add 'declined' as a real end-state status parallel to 'hired'.
-- Rename candidate_source → decline_reason and drop the redundant source column.
-- Motivation: status/candidate_source/source drifted (Jodi was 'assessed' + 'active_applicant_declined').
-- Single-axis truth: status='declined' → decline_reason populated.

-- 1. Add decline_reason column
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS decline_reason text;

-- 2. Update status CHECK to include 'declined'
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_status_check;
ALTER TABLE public.team_assessments
  ADD CONSTRAINT team_assessments_status_check
  CHECK (status IS NULL OR status = ANY (ARRAY[
    'assessed'::text,'email_screen'::text,'interview'::text,'reference_check'::text,
    'offer'::text,'hired'::text,'declined'::text,'archived'::text
  ]));

-- 3. Migrate data: everyone currently archived + not on team → status='declined' with reason from candidate_source
UPDATE public.team_assessments
SET status = 'declined',
    decline_reason = CASE candidate_source
      WHEN 'external_calibration_sample' THEN 'calibration_only'
      WHEN 'former_team_member'          THEN 'former_team'
      WHEN 'active_applicant_declined'   THEN 'active_applicant'
      WHEN 'offer_rescinded'             THEN 'offer_rescinded'
      ELSE NULL
    END,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND status = 'archived'
  AND is_team_member = false;

-- 4. Add decline_reason CHECK
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_decline_reason_check;
ALTER TABLE public.team_assessments
  ADD CONSTRAINT team_assessments_decline_reason_check
  CHECK (decline_reason IS NULL OR decline_reason = ANY (ARRAY[
    'active_applicant'::text,'offer_rescinded'::text,'calibration_only'::text,'former_team'::text
  ]));

-- 5. Drop candidate_source and source columns
ALTER TABLE public.team_assessments DROP COLUMN IF EXISTS candidate_source;
ALTER TABLE public.team_assessments DROP COLUMN IF EXISTS source;
