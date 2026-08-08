-- Phase A2: single `statements` table replacing bank_transactions + credit_transactions.
-- Canon record of what the statement said. Amount is stored STATEMENT-NATIVE:
--   bank rows  -> deposit positive, withdrawal negative
--   credit rows-> charge positive, credit/refund negative
-- account_kind tells the rebuild how to read the sign. No conversion happens here.
-- NOTE: no unique index on (account, date, amount, description) -- genuine same-day
-- identical charges exist (recurring vendors billing twice in a day). Duplicate detection
-- is a review flag, not a constraint.
CREATE TABLE IF NOT EXISTS public.statements (
  id uuid PRIMARY KEY,
  agency_id uuid NOT NULL,
  business_entity_id uuid NOT NULL,
  account_id uuid NOT NULL REFERENCES public.accounts(id),
  account_kind text NOT NULL CHECK (account_kind IN ('bank','credit')),
  transaction_date date NOT NULL,
  description text NOT NULL,
  amount numeric NOT NULL,
  transaction_type text,
  category text,
  reference_number text,
  source_document_id uuid,
  source_message_id text,
  dedup_fingerprint text,
  raw_split_label text,
  receipt_url text,
  notes text,
  superseded_by uuid,
  legacy_journal_entry_id uuid,
  legacy_source_table text NOT NULL CHECK (legacy_source_table IN ('bank_transactions','credit_transactions')),
  posted_at timestamptz,
  created_at timestamptz DEFAULT now()
);

INSERT INTO public.statements (
  id, agency_id, business_entity_id, account_id, account_kind, transaction_date, description,
  amount, transaction_type, category, reference_number, source_document_id, source_message_id,
  dedup_fingerprint, raw_split_label, notes, superseded_by, legacy_journal_entry_id,
  legacy_source_table, posted_at, created_at)
SELECT bt.id, bt.agency_id, bt.business_entity_id, a.id, 'bank', bt.transaction_date, bt.description,
       bt.amount, bt.transaction_type, bt.category, bt.reference_number, bt.source_document_id,
       bt.source_message_id, bt.dedup_fingerprint, bt.raw_split_label, bt.notes, bt.superseded_by,
       bt.journal_entry_id, 'bank_transactions', bt.posted_at, bt.created_at
FROM public.bank_transactions bt
JOIN public.accounts a ON a.chart_account_id = bt.bank_account_id AND a.account_kind = 'bank'
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.statements (
  id, agency_id, business_entity_id, account_id, account_kind, transaction_date, description,
  amount, transaction_type, category, source_document_id, dedup_fingerprint, receipt_url, notes,
  legacy_journal_entry_id, legacy_source_table, posted_at, created_at)
SELECT ct.id, ct.agency_id, ct.business_entity_id, ct.credit_account_id, 'credit', ct.transaction_date,
       ct.description, ct.amount, ct.transaction_type, ct.category, ct.source_document_id,
       ct.dedup_fingerprint, ct.receipt_url, ct.notes,
       ct.journal_entry_id, 'credit_transactions', ct.posted_at, ct.created_at
FROM public.credit_transactions ct
ON CONFLICT (id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_statements_account_date ON public.statements(account_id, transaction_date);
CREATE INDEX IF NOT EXISTS idx_statements_agency_date ON public.statements(agency_id, transaction_date);
CREATE INDEX IF NOT EXISTS idx_statements_document ON public.statements(source_document_id);
CREATE INDEX IF NOT EXISTS idx_statements_dupcheck
  ON public.statements(agency_id, account_id, transaction_date, amount);

ALTER TABLE public.statements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.statements FROM anon, PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.statements TO authenticated;

DROP POLICY IF EXISTS statements_agency_rw ON public.statements;
CREATE POLICY statements_agency_rw ON public.statements
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);