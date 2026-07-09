-- ============================================================================
-- PFA COMPLIANCE SYSTEM (2026-07-09)
-- Premium Fund Account — SF Agent's Agreement compliance tracking.
-- PFA is NOT a business asset (per core_principles/financial_health.pfa);
-- these tables are for SF compliance tracking only, NOT the GL.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.pfa_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE RESTRICT,
  agent_name text NOT NULL,
  agent_code text NOT NULL,
  bank_name text NOT NULL,
  bank_account_number text NOT NULL,
  bank_mailing_address text,
  opened_at date,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pfa_accounts_agency ON public.pfa_accounts(agency_id);

CREATE TABLE IF NOT EXISTS public.pfa_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pfa_account_id uuid NOT NULL REFERENCES public.pfa_accounts(id) ON DELETE RESTRICT,
  transaction_date date NOT NULL,
  transaction_number text,
  transaction_type text NOT NULL CHECK (transaction_type IN (
    'Deposit','State Farm EFT','Bank Service Fee','Personal Deposit',
    'Returned Check','NSF/Overdraft Fee','Interest','Other Withdrawal','Other Credit'
  )),
  description text,
  debit_amount numeric(12,2),
  credit_amount numeric(12,2),
  cleared boolean NOT NULL DEFAULT false,
  cleared_date date,
  cleared_by_statement_id uuid,
  customer_name text,
  policy_or_app_number text,
  prepared_by_team_member_id uuid REFERENCES public.team(id) ON DELETE SET NULL,
  source_document_id uuid REFERENCES public.documents(id) ON DELETE SET NULL,
  notes text,
  imported_from_excel boolean NOT NULL DEFAULT false,
  excel_row_number integer,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT pfa_txn_debit_or_credit CHECK (
    (debit_amount IS NOT NULL AND credit_amount IS NULL AND debit_amount > 0)
    OR (credit_amount IS NOT NULL AND debit_amount IS NULL AND credit_amount > 0)
  ),
  CONSTRAINT pfa_txn_cleared_date_when_cleared CHECK (
    (cleared = false AND cleared_date IS NULL) OR (cleared = true)
  )
);
CREATE INDEX IF NOT EXISTS idx_pfa_transactions_account_date ON public.pfa_transactions(pfa_account_id, transaction_date);
CREATE INDEX IF NOT EXISTS idx_pfa_transactions_uncleared ON public.pfa_transactions(pfa_account_id) WHERE cleared = false;
CREATE INDEX IF NOT EXISTS idx_pfa_transactions_cleared_by ON public.pfa_transactions(cleared_by_statement_id) WHERE cleared_by_statement_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.pfa_bank_statements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pfa_account_id uuid NOT NULL REFERENCES public.pfa_accounts(id) ON DELETE RESTRICT,
  statement_period_start date NOT NULL,
  statement_period_end date NOT NULL,
  opening_balance numeric(12,2) NOT NULL,
  closing_balance numeric(12,2) NOT NULL,
  deposit_count integer,
  deposit_total numeric(12,2),
  withdrawal_count integer,
  withdrawal_total numeric(12,2),
  source_document_id uuid REFERENCES public.documents(id) ON DELETE SET NULL,
  imported_at timestamptz NOT NULL DEFAULT NOW(),
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(pfa_account_id, statement_period_end)
);
CREATE INDEX IF NOT EXISTS idx_pfa_statements_account_end ON public.pfa_bank_statements(pfa_account_id, statement_period_end DESC);

ALTER TABLE public.pfa_transactions
  DROP CONSTRAINT IF EXISTS pfa_transactions_cleared_by_statement_fkey;
ALTER TABLE public.pfa_transactions
  ADD CONSTRAINT pfa_transactions_cleared_by_statement_fkey
  FOREIGN KEY (cleared_by_statement_id) REFERENCES public.pfa_bank_statements(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.pfa_reconciliations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pfa_account_id uuid NOT NULL REFERENCES public.pfa_accounts(id) ON DELETE RESTRICT,
  statement_id uuid NOT NULL REFERENCES public.pfa_bank_statements(id) ON DELETE RESTRICT,
  statement_ending_date date NOT NULL,
  statement_ending_balance numeric(12,2) NOT NULL,
  outstanding_checks_total numeric(12,2) NOT NULL DEFAULT 0,
  outstanding_sf_eft_total numeric(12,2) NOT NULL DEFAULT 0,
  outstanding_deposits_total numeric(12,2) NOT NULL DEFAULT 0,
  returned_checks_unreimbursed numeric(12,2) NOT NULL DEFAULT 0,
  adjusted_statement_balance numeric(12,2) NOT NULL,
  prior_personal_funds numeric(12,2),
  current_bank_service_fees numeric(12,2) NOT NULL DEFAULT 0,
  difference_to_reconcile numeric(12,2) NOT NULL,
  explanation text,
  actions_taken text,
  reconciled_by_team_member_id uuid REFERENCES public.team(id) ON DELETE SET NULL,
  reconciled_at timestamptz,
  printout_document_id uuid REFERENCES public.documents(id) ON DELETE SET NULL,
  email_gmail_draft_id text,
  emailed_to_agent_at timestamptz,
  emailed_to_agent_message_id text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(statement_id)
);
CREATE INDEX IF NOT EXISTS idx_pfa_reconciliations_account_date ON public.pfa_reconciliations(pfa_account_id, statement_ending_date DESC);

CREATE OR REPLACE FUNCTION public.pfa_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pfa_accounts','pfa_transactions','pfa_bank_statements','pfa_reconciliations']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON public.%s', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON public.%s FOR EACH ROW EXECUTE FUNCTION public.pfa_set_updated_at()', t, t);
  END LOOP;
END $$;

ALTER TABLE public.pfa_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pfa_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pfa_bank_statements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pfa_reconciliations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pfa_admin_only_accounts ON public.pfa_accounts;
CREATE POLICY pfa_admin_only_accounts ON public.pfa_accounts
  FOR ALL TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = pfa_accounts.agency_id)
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = pfa_accounts.agency_id)
  );

DROP POLICY IF EXISTS pfa_admin_only_transactions ON public.pfa_transactions;
CREATE POLICY pfa_admin_only_transactions ON public.pfa_transactions
  FOR ALL TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users u
      JOIN public.pfa_accounts a ON a.id = pfa_transactions.pfa_account_id
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = a.agency_id)
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.users u
      JOIN public.pfa_accounts a ON a.id = pfa_transactions.pfa_account_id
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = a.agency_id)
  );

DROP POLICY IF EXISTS pfa_admin_only_statements ON public.pfa_bank_statements;
CREATE POLICY pfa_admin_only_statements ON public.pfa_bank_statements
  FOR ALL TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users u
      JOIN public.pfa_accounts a ON a.id = pfa_bank_statements.pfa_account_id
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = a.agency_id)
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.users u
      JOIN public.pfa_accounts a ON a.id = pfa_bank_statements.pfa_account_id
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = a.agency_id)
  );

DROP POLICY IF EXISTS pfa_admin_only_reconciliations ON public.pfa_reconciliations;
CREATE POLICY pfa_admin_only_reconciliations ON public.pfa_reconciliations
  FOR ALL TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users u
      JOIN public.pfa_accounts a ON a.id = pfa_reconciliations.pfa_account_id
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = a.agency_id)
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.users u
      JOIN public.pfa_accounts a ON a.id = pfa_reconciliations.pfa_account_id
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = a.agency_id)
  );

COMMENT ON TABLE public.pfa_accounts IS 'PFA (Premium Fund Account) metadata — SF compliance tracking only; NOT a business asset. See core_principles financial_health.pfa.';
COMMENT ON TABLE public.pfa_transactions IS 'PFA ledger. Mirrors SF PFA Transaction Register. customer_name + policy_or_app_number are SPI — admin-tier only, never leave the DB except via owner Telegram DMs.';
COMMENT ON TABLE public.pfa_bank_statements IS 'Monthly Frost Bank statement records for PFA reconciliation.';
COMMENT ON TABLE public.pfa_reconciliations IS 'Monthly PFA reconciliation. Generates the printout emailed to the agent SF address.';
