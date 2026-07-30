-- Step B / Item 3 — schema layer
-- Adds cognitive_domain to hiregauge_instrument_items (verbal / math / problem_solving)
-- Adds assessment_source to hiring_candidates ('v1' | 'cts' | NULL)
-- Backfills v1 cognitive items via explicit item_number lists (per prior session negative
-- finding: v1 note format is inconsistent — items 36-53 pipe-delimited, 54-60 free prose)
-- Backfills assessment_source='v1' for the 4 v1-source candidates in the DB

BEGIN;

-- (1) hiregauge_instrument_items.cognitive_domain
ALTER TABLE public.hiregauge_instrument_items
  ADD COLUMN IF NOT EXISTS cognitive_domain text
  CHECK (cognitive_domain IN ('verbal','math','problem_solving') OR cognitive_domain IS NULL);

COMMENT ON COLUMN public.hiregauge_instrument_items.cognitive_domain IS
  'Cognitive subtest domain for LSS aggregation. verbal = letter_series + analogy items; math = number_series + easy/medium word_problem items; problem_solving = hard multi-step word_problem items. Only populated on cognitive-section items.';

-- Backfill v1 cognitive items by explicit item_number
-- Verbal: letter_series (41-45, 56-57) + analogy (46-49, 58-59) = 13 items
UPDATE public.hiregauge_instrument_items
   SET cognitive_domain = 'verbal'
 WHERE section = 'cognitive'
   AND is_active = true
   AND item_number IN (41,42,43,44,45,46,47,48,49,56,57,58,59);

-- Math: number_series (36-40, 54-55) + easy/medium word_problem (50-51, 60) = 10 items
UPDATE public.hiregauge_instrument_items
   SET cognitive_domain = 'math'
 WHERE section = 'cognitive'
   AND is_active = true
   AND item_number IN (36,37,38,39,40,50,51,54,55,60);

-- Problem Solving: hard word_problem (52-53) = 2 items
UPDATE public.hiregauge_instrument_items
   SET cognitive_domain = 'problem_solving'
 WHERE section = 'cognitive'
   AND is_active = true
   AND item_number IN (52,53);

-- (2) hiring_candidates.assessment_source
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS assessment_source text
  CHECK (assessment_source IN ('v1','cts') OR assessment_source IS NULL);

COMMENT ON COLUMN public.hiring_candidates.assessment_source IS
  'Which assessment instrument produced this candidate''s scores. v1 = newtworks in-app assessment (hiregauge_candidate_responses populated). cts = legacy CTS PDF ingest (flat trait/LSS columns populated from PDF parse). NULL = pre-instrument-tagging vintage; primitive treats NULL as cts default.';

-- Backfill v1-source candidates: anyone with hiregauge_candidate_responses = v1
UPDATE public.hiring_candidates hc
   SET assessment_source = 'v1'
 WHERE hc.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND EXISTS (SELECT 1 FROM public.hiregauge_candidate_responses r WHERE r.candidate_id = hc.id)
   AND hc.assessment_source IS NULL;

COMMIT;
