-- ============================================================
-- Step 5B: DESTRUCTIVE — drop 4 legacy ingestion cols
-- 5A shipped, verified, smoke-tested. This drops the redundant flat cols.
-- Index idx_team_assessments_source_gmail auto-drops with source_gmail_message_id.
-- ============================================================

ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS careerplug_metadata,
  DROP COLUMN IF EXISTS candidate_source,
  DROP COLUMN IF EXISTS source_gmail_message_id,
  DROP COLUMN IF EXISTS _legacy_ingestion_metadata;
