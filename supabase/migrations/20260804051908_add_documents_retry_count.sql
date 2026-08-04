-- documents.retry_count
--
-- Supports the mid-flight retry guard added to document-processor on 2026-08-04.
--
-- Problem it exists for: the Gmail fetcher skipped any attachment that already
-- had a documents row, regardless of that row's status. When a run inserted the
-- row and then ended before the handler finished (edge function wall clock), the
-- row sat in a non-terminal status forever and the file was never offered again.
-- Four resumes out of a 143-file backlog run were lost that way, plus three
-- older files including two credit-card statement bundles.
--
-- The fetcher now re-offers non-terminal rows. This counter is what stops a
-- document that fails on every attempt from being picked up on every tick
-- forever; the guard gives up at 3.

ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS retry_count smallint NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.documents.retry_count IS
  'Times document-processor has re-offered this attachment after a run left it in a non-terminal status. Capped at 3 by DOC_MAX_RETRIES in the edge function; not offered again past that.';
