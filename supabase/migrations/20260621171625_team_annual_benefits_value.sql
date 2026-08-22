-- Adds annual_benefits_value (life + health insurance benefits the agency funds per person).
-- Weekly slice = annual / 52 shown in CPR Payroll section.
-- On-time annual = wage projection + annual_benefits_value (flat add, since benefits don't compound with hours/PTO).
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS annual_benefits_value numeric(10,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.team.annual_benefits_value IS
  'Annual $ value of life + health insurance benefits the agency provides this person. Weekly slice = annual / 52 renders in CPR Payroll. Added flat to on-time annual pay projection. Default 0.';
