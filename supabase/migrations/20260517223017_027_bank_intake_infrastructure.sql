-- =============================================================================
-- MIGRATION 027: Bank intake infrastructure
-- =============================================================================
-- (a) bank_account_map: identifier patterns → bank_account_id (chart_of_accounts.id)
--     used by both alert-parser and statement-PDF-parser to resolve "account ending in 3977"
--     → US Bank - Income, etc.
-- (b) bank_transactions: dedup fingerprint + posting_source columns
-- (c) bank_classification_rules: payee/memo patterns → expense category
--     same shape as gl_classification_rules but bank-statement-specific
-- =============================================================================

-- ---- (a) bank_account_map -----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bank_account_map (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  identifier_type text NOT NULL,    -- 'last4', 'sender_email_regex', 'account_number'
  identifier_value text NOT NULL,
  bank_account_id uuid NOT NULL REFERENCES chart_of_accounts(id),
  institution text,
  notes text,
  is_active boolean NOT NULL DEFAULT TRUE,
  priority int NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_bank_account_map_lookup
  ON bank_account_map (agency_id, identifier_type, identifier_value, priority)
  WHERE is_active = TRUE;

-- Seed with known last-4 from Gmail evidence + obvious mappings
INSERT INTO bank_account_map (agency_id, identifier_type, identifier_value, bank_account_id, institution, notes, priority)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid, 'last4', '3977', 
  id, 'US Bank', 'Account ending in 3977 → US Bank - Income (per 5/14, 5/15/2026 deposit alerts). CONFIRM with Peter if Income vs Expenses.', 50
FROM chart_of_accounts WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid 
  AND chart_namespace = 'books_historical' AND account_code = 'COA-007' -- US Bank - Income
UNION ALL
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid, 'last4', '2353',
  id, 'State Farm Federal Credit Union', 'Per chart_of_accounts label "Checking, State Farm (2353)"', 50
FROM chart_of_accounts WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid 
  AND chart_namespace = 'books_historical' AND account_code = 'COA-024'
UNION ALL
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid, 'sender_email_regex', 'usbank@notifications\.usbank\.com',
  id, 'US Bank', 'Default routing for US Bank alert emails without last-4 context. PETER: REVIEW.', 200
FROM chart_of_accounts WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid 
  AND chart_namespace = 'books_historical' AND account_code = 'COA-007'
ON CONFLICT DO NOTHING;

-- ---- (b) bank_transactions: dedup + posting_source -------------------------
ALTER TABLE bank_transactions ADD COLUMN IF NOT EXISTS posting_source text DEFAULT 'unknown';
ALTER TABLE bank_transactions ADD COLUMN IF NOT EXISTS dedup_fingerprint text;
ALTER TABLE bank_transactions ADD COLUMN IF NOT EXISTS source_message_id text;
ALTER TABLE bank_transactions ADD COLUMN IF NOT EXISTS superseded_by uuid REFERENCES bank_transactions(id);

-- Dedup index (unique per fingerprint, excluding superseded rows)
CREATE UNIQUE INDEX IF NOT EXISTS uniq_bank_txn_fingerprint
  ON bank_transactions (agency_id, dedup_fingerprint)
  WHERE dedup_fingerprint IS NOT NULL AND superseded_by IS NULL;

CREATE INDEX IF NOT EXISTS idx_bank_txn_source ON bank_transactions(agency_id, posting_source, posted_at);

-- ---- (c) bank_classification_rules ----------------------------------------
-- A bank-specific classification layer that bank_gl_writer can consult.
-- Already-existing gl_classification_rules works but is more generic.
-- We piggyback on gl_classification_rules instead of duplicating.
-- (Skipped — using existing table.)

SELECT 'migration 027 applied' as status;
