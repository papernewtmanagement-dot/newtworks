-- STEP 2: statement_balances table.
-- One row per (account, statement close date). Feeds "Last Statement" column
-- on Bank + Credit tabs.

CREATE TABLE IF NOT EXISTS public.statement_balances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  business_entity_id uuid,

  account_code text NOT NULL,
  account_last4 text,
  account_kind text NOT NULL CHECK (account_kind IN ('bank','credit')),

  statement_period_start date,
  statement_period_end date NOT NULL,
  opening_balance numeric,
  closing_balance numeric NOT NULL,

  source_document_id uuid,
  source text,
  notes text,

  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS statement_balances_unique_period
  ON public.statement_balances (agency_id, account_code, statement_period_end);

CREATE INDEX IF NOT EXISTS statement_balances_account_end_desc
  ON public.statement_balances (account_code, statement_period_end DESC);

ALTER TABLE public.statement_balances ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS statement_balances_agency_isolation ON public.statement_balances;
CREATE POLICY statement_balances_agency_isolation
  ON public.statement_balances
  FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE OR REPLACE FUNCTION public.tg_statement_balances_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS statement_balances_updated_at ON public.statement_balances;
CREATE TRIGGER statement_balances_updated_at
  BEFORE UPDATE ON public.statement_balances
  FOR EACH ROW EXECUTE FUNCTION public.tg_statement_balances_updated_at();
