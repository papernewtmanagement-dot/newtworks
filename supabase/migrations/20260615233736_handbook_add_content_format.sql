ALTER TABLE public.handbook
  ADD COLUMN IF NOT EXISTS content_format text NOT NULL DEFAULT 'markdown';

-- Sanity check constraint — allow known formats only
ALTER TABLE public.handbook
  DROP CONSTRAINT IF EXISTS handbook_content_format_check;
ALTER TABLE public.handbook
  ADD CONSTRAINT handbook_content_format_check
  CHECK (content_format IN ('markdown', 'plaintext', 'html', 'confluence_storage'));
