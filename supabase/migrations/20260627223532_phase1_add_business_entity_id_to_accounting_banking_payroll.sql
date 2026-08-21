-- Phase 1 of agency_id → business_entity_id refactor
-- Additive only: adds nullable business_entity_id (FK to business_entities) to 15 entity-aware tables.
-- Does NOT remove agency_id. Does NOT change RLS. Does NOT touch SF-agency-specific tables.

-- ACCOUNTING
ALTER TABLE public.journal_entries        ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.journal_lines          ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.chart_of_accounts      ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.account_starting_balances ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.opening_balances       ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.envelope_budget_targets ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);

-- BANKING
ALTER TABLE public.bank_accounts          ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.bank_account_map       ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.bank_transactions      ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.bank_register_preliminary  ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.bank_register_weekly_snapshot ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.credit_accounts        ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.credit_transactions    ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);

-- PAYROLL
ALTER TABLE public.payroll_runs           ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);
ALTER TABLE public.payroll_detail         ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);

-- INDEXES on each
CREATE INDEX IF NOT EXISTS idx_journal_entries_business_entity_id ON public.journal_entries(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_business_entity_id ON public.journal_lines(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_chart_of_accounts_business_entity_id ON public.chart_of_accounts(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_account_starting_balances_business_entity_id ON public.account_starting_balances(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_opening_balances_business_entity_id ON public.opening_balances(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_envelope_budget_targets_business_entity_id ON public.envelope_budget_targets(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_bank_accounts_business_entity_id ON public.bank_accounts(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_bank_account_map_business_entity_id ON public.bank_account_map(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_bank_transactions_business_entity_id ON public.bank_transactions(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_bank_register_preliminary_business_entity_id ON public.bank_register_preliminary(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_bank_register_weekly_snapshot_business_entity_id ON public.bank_register_weekly_snapshot(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_credit_accounts_business_entity_id ON public.credit_accounts(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_credit_transactions_business_entity_id ON public.credit_transactions(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_payroll_runs_business_entity_id ON public.payroll_runs(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_payroll_detail_business_entity_id ON public.payroll_detail(business_entity_id);
