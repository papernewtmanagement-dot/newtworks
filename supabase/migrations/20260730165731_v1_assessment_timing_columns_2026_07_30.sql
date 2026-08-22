-- Step A / Item 4: first-class timing infrastructure for the v1 assessment.
--
-- hiring_candidates gains stamped start/complete timestamps for the taking-window;
-- hiregauge_candidate_responses gains served_at + answered_at for per-item timing.
--
-- served_at is emitted by the v1-assessment edge fn when it hands an item to the
-- candidate and echoed back on save_response. answered_at is written server-clock
-- at save-time. Together they capture end-to-end per-item response time,
-- which feeds straight-through detection (2s Likert convention) in the
-- distortion signals RPC.
--
-- Legacy rows have NULL timing (both response-level and candidate-level). Every
-- downstream reader guards on NULL.

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS assessment_started_at   timestamptz,
  ADD COLUMN IF NOT EXISTS assessment_completed_at timestamptz;

ALTER TABLE public.hiregauge_candidate_responses
  ADD COLUMN IF NOT EXISTS served_at   timestamptz,
  ADD COLUMN IF NOT EXISTS answered_at timestamptz;

COMMENT ON COLUMN public.hiring_candidates.assessment_started_at IS
  'Server-clock time of first save_response for this candidate. Set once by v1-assessment edge fn; never overwritten. NULL for legacy CTS-source candidates.';

COMMENT ON COLUMN public.hiring_candidates.assessment_completed_at IS
  'Server-clock time of successful finalize (only when finalize actually wrote flat trait columns). NULL for legacy or incomplete assessments.';

COMMENT ON COLUMN public.hiregauge_candidate_responses.served_at IS
  'Server-clock ISO 8601 timestamp when the v1-assessment edge fn emitted this item to the candidate. Frontend echoes it back on save_response. Legacy rows: NULL.';

COMMENT ON COLUMN public.hiregauge_candidate_responses.answered_at IS
  'Server-clock timestamp when the response was written. Distinct semantic from created_at (which is a row-level audit stamp); answered_at is intended for the timing signal chain. Legacy rows: NULL.';

