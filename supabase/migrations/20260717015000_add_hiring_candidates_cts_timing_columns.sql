-- Peter directive 2026-07-17: capture response latency between CTS invite
-- and candidate opening it, as a first-class assessment signal. Two nullable
-- timestamps, both populated by intake path (careerplug + manual) going
-- forward; backfill from HireGauge admin history for existing 42 candidates
-- tracked as an open question.
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS cts_invited_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cts_started_at TIMESTAMPTZ;

COMMENT ON COLUMN public.hiring_candidates.cts_invited_at IS
'When the CTS invite was sent to the candidate. Source: HireGauge admin history (existing candidates) or captured at invite-send time (future). Feeds response-latency signal: cts_started_at - cts_invited_at. NULL means unknown — do not infer from assessment_date.';

COMMENT ON COLUMN public.hiring_candidates.cts_started_at IS
'When the candidate opened the CTS assessment. Source: HireGauge admin history. Feeds response-latency signal alongside cts_invited_at. NULL means unknown — cts_wall_duration_seconds captures how long they spent taking it, but not when they began.';
