-- Newtworks v1 Stint 2 build, step 2 of 10 per handoff 2026-07-28.
-- Adds sitting column to candidate responses table.
--   sitting=1 : primary assessment (every candidate)
--   sitting=2 : optional 2-4 week retest for finalists (~30 items)
--   sitting=3+: further retests if we later want them
-- Default 1 backfills every existing response as primary sitting,
-- which is correct — nothing has been retested yet.
ALTER TABLE public.hiregauge_candidate_responses
  ADD COLUMN IF NOT EXISTS sitting integer NOT NULL DEFAULT 1;

-- Compound index for the scoring function's typical read path:
-- "give me every response for candidate X at sitting Y".
CREATE INDEX IF NOT EXISTS idx_hiregauge_candidate_responses_candidate_sitting
  ON public.hiregauge_candidate_responses (candidate_id, sitting);
