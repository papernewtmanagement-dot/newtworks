
-- Additive column mirroring llm_parse_queue.reconciliation_delta so the
-- synchronous document-processor guard path has a matching audit field.
-- The drainer path (llm-queue-drainer v5) records delta on llm_parse_queue;
-- document-processor writes to documents.reconciliation_delta for the
-- synchronous parse branch since it does not create a queue row.
ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS reconciliation_delta numeric;

COMMENT ON COLUMN public.documents.reconciliation_delta IS
  'Reconciliation guard delta for bank/credit statement parses: closing - (opening + sum(txn.amount)). Near-zero on success, larger than epsilon means held_reconciliation_mismatch. NULL when guard did not run (non-statement documents or missing balances). Mirrors llm_parse_queue.reconciliation_delta for the synchronous document-processor path.';

