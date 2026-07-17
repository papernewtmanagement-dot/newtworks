-- Add reference-only ingestion audit trail column on hiring_candidates.
-- Per Peter directive 2026-07-17: no displayed text field on hiring_candidates
-- should carry ingestion metadata (source, doc names, msg IDs, drive URLs).
-- Anything ingestion-related that must be preserved for reference goes here
-- and is NEVER rendered on user-facing surfaces.
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS ingestion_metadata JSONB;

COMMENT ON COLUMN public.hiring_candidates.ingestion_metadata IS
'Non-displayed reference-only ingestion audit trail: source, ingest timestamp, msg IDs, drive file URLs, ingested_by, workflow_events. Used for manual and non-CareerPlug ingests. Never render on any user-facing surface. Peter directive 2026-07-17: hiring_candidates displayed text fields must not carry ingestion metadata.';
