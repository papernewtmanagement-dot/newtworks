-- Add columns to hold LLM-generated, per-candidate interview probes.
-- custom_probes is jsonb (see edge fn generate-custom-probes for shape).
-- custom_probes_generated_at is set by the edge fn on successful write.

ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS custom_probes            jsonb,
  ADD COLUMN IF NOT EXISTS custom_probes_generated_at timestamptz;

COMMENT ON COLUMN public.team_assessments.custom_probes IS
  'LLM-generated per-candidate interview probes (structured JSON). Written by edge fn generate-custom-probes. Read by CandidateDetail.jsx "Customized Interview Probes" section.';

COMMENT ON COLUMN public.team_assessments.custom_probes_generated_at IS
  'Timestamp of the most recent generate-custom-probes edge fn run for this row.';
