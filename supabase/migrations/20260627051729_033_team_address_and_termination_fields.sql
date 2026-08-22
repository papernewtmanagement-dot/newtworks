-- Address captured at hire; rendered in the termination notification email.
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS address_line1 text,
  ADD COLUMN IF NOT EXISTS address_line2 text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS state text,
  ADD COLUMN IF NOT EXISTS zip_code text,
  ADD COLUMN IF NOT EXISTS termination_reason text,
  ADD COLUMN IF NOT EXISTS final_paycheck_date date;

COMMENT ON COLUMN public.team.address_line1 IS 'Physical address line 1. Captured at hire; rendered in termination notice email to Peter SF.';
COMMENT ON COLUMN public.team.address_line2 IS 'Physical address line 2 (apt/unit/suite). Optional.';
COMMENT ON COLUMN public.team.city IS 'City of residence.';
COMMENT ON COLUMN public.team.state IS 'State abbreviation (e.g. TX).';
COMMENT ON COLUMN public.team.zip_code IS 'ZIP code.';
COMMENT ON COLUMN public.team.termination_reason IS 'Free-text reason recorded by the HRPeople Terminate flow. Mirrors the team_behavioral_notes audit row for quick reference.';
COMMENT ON COLUMN public.team.final_paycheck_date IS 'Optional final paycheck date set during termination. May differ from end_date when severance or final commission accrual lands later.';
