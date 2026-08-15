-- Gap in the original Phase 3 scoring migration (2026-08-14): the edge
-- function and scoring functions were wired to write assessment_source =
-- 'v2fc', but nothing ever widened this CHECK constraint to allow that
-- value. This meant EVERY forced-choice candidate's finalize write would
-- have failed at the database layer, not just Alvi's -- caught live via her
-- test completion, same incident as the assessment_date column drop.
ALTER TABLE public.hiring_candidates DROP CONSTRAINT hiring_candidates_assessment_source_check;
ALTER TABLE public.hiring_candidates ADD CONSTRAINT hiring_candidates_assessment_source_check
  CHECK (assessment_source = ANY (ARRAY['v1'::text, 'v2'::text, 'cts'::text, 'v2fc'::text]) OR assessment_source IS NULL);
