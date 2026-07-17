-- Add SalesManageSolutions history timing fields to hiring_candidates.
-- Sources: per-candidate History screens showing invited/started/completed events for EPQ, VCT, LSS, CTS.
-- All times stored in UTC; source screens display America/Chicago local time.

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS cts_invited_by text,
  ADD COLUMN IF NOT EXISTS cts_completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS epq_started_at   timestamptz,
  ADD COLUMN IF NOT EXISTS epq_completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS vct_started_at   timestamptz,
  ADD COLUMN IF NOT EXISTS vct_completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS lss_started_at   timestamptz,
  ADD COLUMN IF NOT EXISTS lss_completed_at timestamptz;

COMMENT ON COLUMN public.hiring_candidates.cts_invited_by     IS 'Name of person who invited candidate to take CTS (from SalesManageSolutions history)';
COMMENT ON COLUMN public.hiring_candidates.cts_completed_at   IS 'When candidate completed CTS section';
COMMENT ON COLUMN public.hiring_candidates.epq_started_at     IS 'When candidate started EPQ section';
COMMENT ON COLUMN public.hiring_candidates.epq_completed_at   IS 'When candidate completed EPQ section';
COMMENT ON COLUMN public.hiring_candidates.vct_started_at     IS 'When candidate started VCT section';
COMMENT ON COLUMN public.hiring_candidates.vct_completed_at   IS 'When candidate completed VCT section';
COMMENT ON COLUMN public.hiring_candidates.lss_started_at     IS 'When candidate started LSS section';
COMMENT ON COLUMN public.hiring_candidates.lss_completed_at   IS 'When candidate completed LSS section';
