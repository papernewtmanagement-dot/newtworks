-- Cache column for text extracted from documents (currently: resume PDFs pulled
-- from Google Drive via Composio, extracted with unpdf inside the
-- generate-custom-probes edge fn). Populated lazily on first read.

ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS extracted_text  text,
  ADD COLUMN IF NOT EXISTS extracted_at    timestamptz;

COMMENT ON COLUMN public.documents.extracted_text IS
  'Plain-text extraction of the document (PDF text layer via unpdf). Populated lazily on first read by edge fns that need document content. NULL means never extracted or extraction failed.';

COMMENT ON COLUMN public.documents.extracted_at IS
  'Timestamp of the most recent successful text extraction.';
