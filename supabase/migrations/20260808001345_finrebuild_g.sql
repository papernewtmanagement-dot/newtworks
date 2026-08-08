-- Phase A1: single `accounts` table replacing bank_accounts + credit_accounts.
-- Original ids are preserved so credit_transactions.credit_account_id repoints without remapping.
CREATE TABLE IF NOT EXISTS public.accounts (
  id uuid PRIMARY KEY,
  agency_id uuid NOT NULL,
  business_entity_id uuid NOT NULL,
  account_kind text NOT NULL CHECK (account_kind IN ('bank','credit')),
  account_name text NOT NULL,
  institution text NOT NULL,
  account_type text,
  account_number_last4 text,
  alternate_last4s text[],
  routing_number_last4 text,
  chart_account_id uuid REFERENCES public.chart_of_accounts(id),
  statement_close_day smallint,
  credit_limit numeric,
  interest_rate numeric,
  minimum_payment numeric,
  payment_due_day integer,
  is_primary boolean DEFAULT false,
  is_active boolean DEFAULT true,
  legacy_current_balance numeric,
  legacy_as_of_date date,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

INSERT INTO public.accounts (
  id, agency_id, business_entity_id, account_kind, account_name, institution, account_type,
  account_number_last4, alternate_last4s, routing_number_last4, chart_account_id,
  statement_close_day, is_primary, is_active, legacy_current_balance, legacy_as_of_date,
  created_at, updated_at)
SELECT ba.id, ba.agency_id, ba.business_entity_id, 'bank', ba.account_name, ba.institution,
       ba.account_type, ba.account_number_last4, NULL, ba.routing_number_last4, ba.chart_account_id,
       ba.statement_close_day, COALESCE(ba.is_primary,false), COALESCE(ba.is_active,true),
       ba.current_balance, ba.as_of_date, ba.created_at, ba.updated_at
FROM public.bank_accounts ba
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.accounts (
  id, agency_id, business_entity_id, account_kind, account_name, institution, account_type,
  account_number_last4, alternate_last4s, routing_number_last4, chart_account_id,
  statement_close_day, credit_limit, interest_rate, minimum_payment, payment_due_day,
  is_primary, is_active, legacy_current_balance, created_at, updated_at)
SELECT ca.id, ca.agency_id, ca.business_entity_id, 'credit', ca.account_name, ca.institution,
       ca.account_type, ca.account_number_last4, ca.alternate_last4s, NULL, ca.chart_account_id,
       ca.statement_close_day, ca.credit_limit, ca.interest_rate, ca.minimum_payment,
       ca.payment_due_day, false, COALESCE(ca.is_active,true),
       ca.current_balance, ca.created_at, ca.updated_at
FROM public.credit_accounts ca
ON CONFLICT (id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_accounts_agency_kind ON public.accounts(agency_id, account_kind);
CREATE INDEX IF NOT EXISTS idx_accounts_chart ON public.accounts(chart_account_id);
CREATE INDEX IF NOT EXISTS idx_accounts_last4 ON public.accounts(account_number_last4);

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.accounts FROM anon, PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.accounts TO authenticated;

DROP POLICY IF EXISTS accounts_agency_rw ON public.accounts;
CREATE POLICY accounts_agency_rw ON public.accounts
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);