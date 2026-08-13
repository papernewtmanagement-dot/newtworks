-- =====================================================================
-- candidate_email_responses: add the runner's plumbing column
-- =====================================================================
-- WHY THIS COLUMN EXISTS ALONGSIDE gmail_message_id.
--
-- automation-runner hardcodes the name `source_message_id` in TWO places
-- and neither is configurable per recipe:
--
--   1. Dedupe. Before handing messages to Groq it runs
--        select("source_message_id").in("source_message_id", fetchedIds)
--      against the recipe's output_table. That read is wrapped in
--      `if (!dedupErr)` -- so when the column does NOT exist the error is
--      SWALLOWED and dedupe is silently SKIPPED rather than failing loudly.
--      On a 15-minute cron that means every message in the query window is
--      re-parsed and re-inserted on every single tick. This is the real
--      failure mode: not a crash, a slow flood.
--
--   2. Post-parse archive. It reads source_message_id off each parsed
--      record to know which Gmail messages to strip INBOX from.
--
-- gmail_message_id is the semantic column and is NOT being renamed,
-- repointed or retired. Both columns carry the same value; the BEFORE
-- INSERT trigger (next migration) mirrors whichever one a writer supplies
-- into the other, so hand-written inserts and runner-written inserts both
-- end up complete.
--
-- The index must be FULL, not partial. The existing
-- uq_candidate_email_responses_message is partial
-- (WHERE gmail_message_id IS NOT NULL), and Postgres cannot infer a
-- partial index as an ON CONFLICT target unless the statement carries a
-- matching WHERE clause -- which PostgREST's upsert never does. A partial
-- index here would make writeOutput() throw
-- "no unique or exclusion constraint matching the ON CONFLICT
-- specification" on every run.
-- =====================================================================

ALTER TABLE public.candidate_email_responses
  ADD COLUMN IF NOT EXISTS source_message_id text;

COMMENT ON COLUMN public.candidate_email_responses.source_message_id IS
  'Gmail message id, duplicated from gmail_message_id under the name automation-runner hardcodes for dedupe + post-parse archive. Kept in sync both directions by trg_candidate_email_response_resolve. Not a replacement for gmail_message_id.';

UPDATE public.candidate_email_responses
   SET source_message_id = gmail_message_id
 WHERE source_message_id IS NULL
   AND gmail_message_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_candidate_email_responses_source_message
  ON public.candidate_email_responses (agency_id, source_message_id);
