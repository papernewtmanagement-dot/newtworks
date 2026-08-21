-- =====================================================================
-- Migration 024: enable PDF-extraction queue path (Session 12 part 3)
-- =====================================================================
-- Why: the Edge Function can't extract text from PDFs (Composio tool slug
-- was fictional; no PDF toolkit connected). Instead, the Edge Function
-- stashes PDF bytes in Supabase Storage and queues a job; a workbench
-- drainer pulls each job, runs smart_file_extract on the bytes, runs the
-- appropriate downstream parser, then closes the job.
-- =====================================================================

-- Storage bucket for PDF bytes awaiting extraction. Not public — only the
-- service role + workbench (via service role key) can read. TTL: drainer
-- deletes files after successful extraction; failed extracts keep bytes
-- around for retries.
INSERT INTO storage.buckets (id, name, public)
VALUES ('pdf-extract-queue', 'pdf-extract-queue', false)
ON CONFLICT (id) DO NOTHING;

-- Queue table columns: reference the stored object + carry the docType
-- the orchestrator wants run AFTER text is extracted.
ALTER TABLE llm_parse_queue
  ADD COLUMN IF NOT EXISTS storage_bucket TEXT,
  ADD COLUMN IF NOT EXISTS storage_path   TEXT,
  ADD COLUMN IF NOT EXISTS file_name      TEXT,
  ADD COLUMN IF NOT EXISTS mime_type      TEXT,
  ADD COLUMN IF NOT EXISTS doc_type       TEXT,   -- e.g. 'comp_recap_daily', so drainer knows which parser to chain to
  ADD COLUMN IF NOT EXISTS extracted_text TEXT;   -- populated by drainer after smart_file_extract

-- Index for drainer claim
CREATE INDEX IF NOT EXISTS idx_llm_parse_queue_pending_purpose
  ON llm_parse_queue (purpose, status, created_at)
  WHERE status = 'pending';

COMMENT ON COLUMN llm_parse_queue.storage_bucket IS 'Supabase Storage bucket holding raw bytes when purpose=parse_pdf_to_text';
COMMENT ON COLUMN llm_parse_queue.storage_path   IS 'Object path within storage_bucket. Format: agency_id/document_id.pdf';
COMMENT ON COLUMN llm_parse_queue.doc_type       IS 'Routes the workbench drainer to the right downstream parser after text extraction';
COMMENT ON COLUMN llm_parse_queue.extracted_text IS 'Populated by the workbench drainer after smart_file_extract. Available for re-runs.';
