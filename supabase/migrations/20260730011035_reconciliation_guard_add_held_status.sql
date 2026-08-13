-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 01:10:35 UTC (ledger name: reconciliation_guard_add_held_status) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730011035.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Extend llm_parse_queue.status CHECK with held_reconciliation_mismatch
ALTER TABLE public.llm_parse_queue
  DROP CONSTRAINT IF EXISTS llm_parse_queue_status_check;

ALTER TABLE public.llm_parse_queue
  ADD CONSTRAINT llm_parse_queue_status_check
  CHECK (status = ANY (ARRAY[
    'pending',
    'processing',
    'succeeded',
    'failed',
    'abandoned',
    'held_reconciliation_mismatch'
  ]::text[]));

-- Add reconciliation_delta column for observability
ALTER TABLE public.llm_parse_queue
  ADD COLUMN IF NOT EXISTS reconciliation_delta numeric;

COMMENT ON COLUMN public.llm_parse_queue.reconciliation_delta IS
  'Bank/credit statement parse reconciliation delta: opening + sum(txn amounts) - closing. Populated when guard evaluates. Null when guard did not apply (non-statement purpose) or when the statement reconciled cleanly.';
