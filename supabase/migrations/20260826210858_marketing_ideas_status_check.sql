-- Closes open_question 731dbf2e: restrict marketing_ideas.status to the six canonical buckets.
-- Verified 2026-08-26: only value in use is 'backlog'.
ALTER TABLE public.marketing_ideas DROP CONSTRAINT IF EXISTS marketing_ideas_status_check;
ALTER TABLE public.marketing_ideas ADD CONSTRAINT marketing_ideas_status_check
  CHECK (status IS NULL OR status IN ('backlog','next_review','approved','in_flight','done','rejected'));
