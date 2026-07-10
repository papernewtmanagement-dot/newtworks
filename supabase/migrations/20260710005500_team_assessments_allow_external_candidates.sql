-- Extend team_assessments to hold CTS/LSS profiles for people who are not (yet) team members.
-- Phase 2 CTS calibration widening: 21 external samples from Peter's SF-forwarded CTS profiles email 2026-07-09.

-- 1. Allow team_member_id to be NULL for external candidates.
ALTER TABLE public.team_assessments
  ALTER COLUMN team_member_id DROP NOT NULL;

-- 2. Add candidate identity columns.
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS candidate_name text,
  ADD COLUMN IF NOT EXISTS candidate_source text;

-- 3. Require exactly one identity anchor (team member OR named external candidate).
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_identity_check;
ALTER TABLE public.team_assessments
  ADD CONSTRAINT team_assessments_identity_check
    CHECK ((team_member_id IS NOT NULL) OR (candidate_name IS NOT NULL AND length(trim(candidate_name)) > 0));

COMMENT ON COLUMN public.team_assessments.candidate_name IS 'Name of external candidate (not yet a team member). NULL when team_member_id is set. Populated for CTS calibration widening samples and hiring candidates.';
COMMENT ON COLUMN public.team_assessments.candidate_source IS 'Provenance tag for external candidates. e.g. external_calibration_sample, hiring_applicant. NULL for team members.';
