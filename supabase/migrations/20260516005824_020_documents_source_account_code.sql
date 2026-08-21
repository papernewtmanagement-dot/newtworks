-- ============================================================
-- 020_documents_source_account_code
-- Adds source_account_code to documents so the drainer/Edge
-- Function can post bank txns against the correct GL account
-- instead of the hardcoded US Bank fallback.
-- ============================================================

ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS source_account_code text;

COMMENT ON COLUMN public.documents.source_account_code IS
  'GL account code (e.g. COA-007) inferred at intake. Used by drainer + GL poster to attribute bank txns to the correct source account. Resolved from sender email / subject via resolveSourceAccount() in document-processor index.ts.';

-- Optional index: drainer joins documents on id when draining, so
-- a separate index isn't required; documents.id is already the PK.
