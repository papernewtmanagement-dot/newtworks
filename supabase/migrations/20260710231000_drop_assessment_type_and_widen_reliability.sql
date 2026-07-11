-- Drop assessment_type: role-fit is now a function-based projection over 4 role lenses
-- (cts_sales_os, cts_service_os, cts_service_sales_os, cts_aspirant_os). The single
-- physical test is viewed through all four; storing "which variant they took" no longer
-- carries meaningful information.
ALTER TABLE public.team_assessments
  DROP COLUMN IF EXISTS assessment_type;

-- Widen reliability CHECK to include 'very_high' (source assessment PDFs use this label;
-- prior 3-value constraint was forcing it to 'high' and losing signal).
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS staff_assessments_reliability_check;

ALTER TABLE public.team_assessments
  ADD CONSTRAINT staff_assessments_reliability_check
  CHECK (reliability = ANY (ARRAY['low','moderate','high','very_high']));

-- Widen response_distortion CHECK to include very_low/very_high symmetrically.
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS staff_assessments_response_distortion_check;

ALTER TABLE public.team_assessments
  ADD CONSTRAINT staff_assessments_response_distortion_check
  CHECK (response_distortion = ANY (ARRAY['low','moderate','high','very_low','very_high']));
