-- Correction of the earlier migration (20260720230000): dedupe key is
-- (gmail_message_id, file_name), not (gmail_message_id, gmail_attachment_id).
-- Gmail attachment IDs are ephemeral (rotate across API calls, verified
-- 2026-07-20 - same attachment returned different IDs on two calls).
-- File names within a single message are unique in practice.

DROP INDEX IF EXISTS public.idx_documents_gmail_dedupe;

CREATE INDEX IF NOT EXISTS idx_documents_gmail_dedupe
  ON public.documents (agency_id, gmail_message_id, file_name)
  WHERE gmail_message_id IS NOT NULL;

COMMENT ON COLUMN public.documents.gmail_attachment_id IS
  'Gmail attachment ID at ingest time. NOTE: Gmail attachment IDs are ephemeral (rotate across API calls), so this is auxiliary/debugging only. Do NOT use as an idempotency key. See idx_documents_gmail_dedupe for the actual dedupe key.';
