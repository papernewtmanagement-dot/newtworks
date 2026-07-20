-- Fix for doc-processor idempotency bug surfaced 2026-07-20:
-- Prior dedupe on (agency_id, file_name, upload_source LIKE gmail%, 30d) silently
-- skipped generic-named repeats. SF sent "Payroll Summary.pdf" whose name collided
-- with a legacy row from 2026-07-06 -> new email got dropped at the classifier.
-- Move to (gmail_message_id, gmail_attachment_id) which is globally unique.

ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS gmail_attachment_id text;

COMMENT ON COLUMN public.documents.gmail_attachment_id IS
  'Gmail-side attachment ID (per-part). With gmail_message_id, uniquely identifies a Gmail attachment. Written by document-processor for outer attachments; NULL for inner-from-zip and non-gmail uploads.';

CREATE INDEX IF NOT EXISTS idx_documents_gmail_dedupe
  ON public.documents (agency_id, gmail_message_id, gmail_attachment_id)
  WHERE gmail_message_id IS NOT NULL AND gmail_attachment_id IS NOT NULL;
