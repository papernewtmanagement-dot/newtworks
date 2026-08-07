-- llm_parse_queue.target_ref
--
-- WHY: a queued LLM job needs to know WHERE its result goes. Bank-statement and
-- careerplug jobs carry that pointer implicitly (document_id, or the payload
-- itself identifies the candidate). wrapup_organize jobs do not: the row they
-- must write back to is a specific weekly_cpr_team_detail row, and nothing in
-- the queue schema recorded it. Result (found 2026-08-07): John Kostov's
-- 2026-08-06 wrap-up was queued when Groq was over quota, the source email was
-- labeled + archived so the 30-minute cron would stop re-fetching it, and the
-- job was then undrainable and invisible. The wrap-up was recovered by hand.
--
-- target_ref is a free-form pointer written by the enqueueing caller and read by
-- llm-queue-drainer. Deliberately generic (no FK, no shape constraint) so new
-- purposes can describe their own write target without another migration.
-- Shape used by wrapup_organize:
--   {"table":"weekly_cpr_team_detail","detail_id":"<uuid>","team_member_id":"<uuid>",
--    "week_ending_date":"YYYY-MM-DD","gmail_message_id":"<id>"}
ALTER TABLE public.llm_parse_queue
  ADD COLUMN IF NOT EXISTS target_ref jsonb;

COMMENT ON COLUMN public.llm_parse_queue.target_ref IS
  'Caller-supplied pointer to the row/record this queued job must write its result back to. Read by llm-queue-drainer. No fixed shape; see the purpose-specific handler. NULL for purposes whose write target is implied by document_id or by the parsed payload itself.';
