-- Add structured weekly benefit fields to team table
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS weekly_life_benefit_agency_paid NUMERIC(8,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS weekly_health_benefit_agency_paid NUMERIC(8,2) DEFAULT 0;

COMMENT ON COLUMN public.team.weekly_life_benefit_agency_paid IS 'Weekly dollar amount the agency contributes toward this team member''s life insurance benefit. Multiply by 52 for annual.';
COMMENT ON COLUMN public.team.weekly_health_benefit_agency_paid IS 'Weekly dollar amount the agency contributes toward this team member''s group health insurance premium (excludes employee-paid portion). Multiply by 52 for annual.';
