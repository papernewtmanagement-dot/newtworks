-- 20260719080000_tighten_reliability_distortion_checks.sql
-- Peter directive 2026-07-19: reliability + distortion are 3-level ordinals in the vendor's ratings.
-- Normalize the one anomalous very_high reliability row (unnamed, March 2025) to 'high',
-- then tighten CHECK constraints to just low/moderate/high on both columns.

-- 1) normalize anomalous row
UPDATE public.hiring_candidates
   SET reliability = 'high'
 WHERE reliability = 'very_high';

-- 2) tighten reliability CHECK to 3 levels
ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS staff_assessments_reliability_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_reliability_check
  CHECK (reliability IS NULL OR reliability IN ('low','moderate','high'));

-- 3) tighten response_distortion CHECK to 3 levels
ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS staff_assessments_response_distortion_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_response_distortion_check
  CHECK (response_distortion IS NULL OR response_distortion IN ('low','moderate','high'));
