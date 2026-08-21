-- Rescale resume_quality from 1-10 to 0-100 per Peter directive 2026-07-23
-- No frontend/SQL logic depends on the 1-10 scale (grep confirmed).
-- Only 1 existing row has a non-null value (Alyssa Sapp @ 7) — rescaled to 70.

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS team_assessments_resume_quality_check;

-- Rescale existing values *10 to preserve semantic ordering
UPDATE public.hiring_candidates
SET resume_quality = resume_quality * 10
WHERE resume_quality IS NOT NULL
  AND resume_quality <= 10;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_resume_quality_check
  CHECK (resume_quality IS NULL OR (resume_quality >= 0 AND resume_quality <= 100));

COMMENT ON COLUMN public.hiring_candidates.resume_quality IS
  'Resume quality score, 0-100 scale (rescaled from prior 1-10 scale on 2026-07-23 per Peter agency-wide 0-100 grading convention).';
