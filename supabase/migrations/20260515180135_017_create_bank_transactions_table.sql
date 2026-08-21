-- =========================================================================
-- bank_transactions — mirrors credit_transactions structure
-- =========================================================================
-- Detail table for bank statement transactions. Mirrors credit_transactions.
-- The Bank Statement Processor recipe will write here. A future sibling 
-- INTERNAL handler (bank_gl_writer) will reconcile these into journal_entries
-- post-cutover, leaving pre-cutover rows as archive-only.
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.bank_transactions (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id         UUID REFERENCES public.agency(id) ON DELETE CASCADE,
  bank_account_id   UUID REFERENCES public.chart_of_accounts(id),
  transaction_date  DATE NOT NULL,
  description       TEXT NOT NULL,
  amount            NUMERIC NOT NULL,
  transaction_type  TEXT,    -- 'deposit', 'withdrawal', 'transfer', 'fee', 'interest'
  journal_entry_id  UUID REFERENCES public.journal_entries(id),  -- populated by future bank_gl_writer
  category          TEXT,
  reference_number  TEXT,    -- check #, ACH ref, etc.
  source_document_id UUID REFERENCES public.documents(id),       -- link back to the source statement PDF
  raw_split_label   TEXT,    -- preserves the COA-style SPLIT label from the statement for later sub-account resolution
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

-- Unique constraint matching the Bank Statement Processor's unique_on config
CREATE UNIQUE INDEX IF NOT EXISTS uq_bank_transactions_dedup
  ON public.bank_transactions (agency_id, bank_account_id, transaction_date, amount, description);

-- Read indexes
CREATE INDEX IF NOT EXISTS idx_bank_transactions_agency_date 
  ON public.bank_transactions (agency_id, transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_bank_transactions_journal_entry 
  ON public.bank_transactions (journal_entry_id) WHERE journal_entry_id IS NOT NULL;

-- RLS: enable and grant anon read (matching migration 005 pattern)
ALTER TABLE public.bank_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_read_bank_transactions ON public.bank_transactions;
CREATE POLICY anon_read_bank_transactions
  ON public.bank_transactions FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS service_role_all_bank_transactions ON public.bank_transactions;
CREATE POLICY service_role_all_bank_transactions
  ON public.bank_transactions FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT SELECT ON public.bank_transactions TO anon;
GRANT ALL ON public.bank_transactions TO service_role;
