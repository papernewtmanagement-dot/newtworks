-- 033_team_address_and_termination_fields.sql
--
-- Adds address columns + termination metadata to public.team.
--
-- Address fields are captured at hire (HRPeople add-member form) and rendered
-- in the termination notice email sent by the terminate-team-member edge fn.
-- Existing active members will have NULL address values until edited;
-- the email handles that gracefully ("[not on file]").
--
-- termination_reason mirrors what the user typed in the termination modal so
-- a single SELECT against team gives the why without joining team_behavioral_notes.
-- final_paycheck_date is optional — may differ from end_date when severance or
-- final commission accrual lands later.

ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS address_line1 text,
  ADD COLUMN IF NOT EXISTS address_line2 text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS state text,
  ADD COLUMN IF NOT EXISTS zip_code text,
  ADD COLUMN IF NOT EXISTS termination_reason text,
  ADD COLUMN IF NOT EXISTS final_paycheck_date date;

COMMENT ON COLUMN public.team.address_line1
  IS 'Physical address line 1. Captured at hire; rendered in termination notice email to Peter SF.';
COMMENT ON COLUMN public.team.address_line2
  IS 'Physical address line 2 (apt/unit/suite). Optional.';
COMMENT ON COLUMN public.team.city       IS 'City of residence.';
COMMENT ON COLUMN public.team.state      IS 'State abbreviation (e.g. TX).';
COMMENT ON COLUMN public.team.zip_code   IS 'ZIP code.';
COMMENT ON COLUMN public.team.termination_reason
  IS 'Free-text reason recorded by the HRPeople Terminate flow.';
COMMENT ON COLUMN public.team.final_paycheck_date
  IS 'Optional final paycheck date set during termination. May differ from end_date.';
