-- 1. Drop assessment_type column: obsolete now that role-fit is a function-based projection.
--    Best-fit-role derives from traits, not from what version of the test the candidate took.
--    The single physical test is now viewed through 4 role lenses via cts_*_os functions.
ALTER TABLE public.team_assessments
  DROP COLUMN IF EXISTS assessment_type;

-- 2. Widen reliability CHECK to include 'very_high' (source PDFs use this label; prior constraint forced it to 'high' and lost signal).
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS staff_assessments_reliability_check;

ALTER TABLE public.team_assessments
  ADD CONSTRAINT staff_assessments_reliability_check
  CHECK (reliability = ANY (ARRAY['low','moderate','high','very_high']));

-- 3. Widen response_distortion CHECK to match (in case some PDFs report 'very_low'/'very_high' there too — defensive)
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS staff_assessments_response_distortion_check;

ALTER TABLE public.team_assessments
  ADD CONSTRAINT staff_assessments_response_distortion_check
  CHECK (response_distortion = ANY (ARRAY['low','moderate','high','very_low','very_high']));
