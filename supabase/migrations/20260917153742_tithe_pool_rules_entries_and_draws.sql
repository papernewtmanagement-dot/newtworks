-- Tithe pool. Money is set aside automatically as a share of income that comes
-- in, and any transaction can be marked as coming out of the pool no matter what
-- expense account it sits in on the P&L.

-- ── one home for the income/expense sign convention ───────────────────────────
-- Income normally reads credit minus debit. Income brought over from the old
-- books reads the other way round. Expense always reads debit minus credit.
-- pnl_drill_transactions had this spelled out inline; it now calls this instead,
-- so the tithe math and the P&L can never drift apart.
CREATE OR REPLACE FUNCTION public.ledger_pnl_amount(
  p_debit numeric,
  p_credit numeric,
  p_account_type text,
  p_ledger_source text
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_account_type = 'income'  AND COALESCE(p_ledger_source,'') LIKE 'historical_import%'
      THEN COALESCE(p_debit,0) - COALESCE(p_credit,0)
    WHEN p_account_type = 'income'  THEN COALESCE(p_credit,0) - COALESCE(p_debit,0)
    WHEN p_account_type = 'expense' THEN COALESCE(p_debit,0)  - COALESCE(p_credit,0)
    ELSE 0
  END;
$$;

COMMENT ON FUNCTION public.ledger_pnl_amount(numeric, numeric, text, text) IS
  'The single home for how a ledger row turns into a P&L amount. Called by pnl_drill_transactions and by the tithe pool so the two can never disagree.';


-- ── the percentages ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tithe_pool_rules (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id          uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  rule_name          text NOT NULL,
  income_account_id  uuid NOT NULL REFERENCES public.chart_of_accounts(id) ON DELETE CASCADE,
  percent            numeric(7,4) NOT NULL CHECK (percent >= 0 AND percent <= 100),
  effective_from     date NOT NULL DEFAULT '2026-01-01',
  effective_to       date,
  is_active          boolean NOT NULL DEFAULT true,
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE UNIQUE INDEX IF NOT EXISTS tithe_pool_rules_one_per_account_period
  ON public.tithe_pool_rules (agency_id, income_account_id, effective_from)
  WHERE is_active;

COMMENT ON TABLE public.tithe_pool_rules IS
  'How much of each kind of income goes into the tithe pool. One row per income account per effective date.';


-- ── what has been set aside ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tithe_pool_entries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  entry_date        date NOT NULL,
  direction         text NOT NULL CHECK (direction IN ('accrual','adjustment')),
  amount            numeric(14,2) NOT NULL,
  description       text,
  source_ledger_id  uuid REFERENCES public.ledger(id) ON DELETE CASCADE,
  rule_id           uuid REFERENCES public.tithe_pool_rules(id) ON DELETE CASCADE,
  income_amount     numeric(14,2),
  percent_applied   numeric(7,4),
  created_by        text NOT NULL DEFAULT 'system',
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS tithe_pool_entries_one_accrual_per_row_rule
  ON public.tithe_pool_entries (source_ledger_id, rule_id)
  WHERE direction = 'accrual';

CREATE INDEX IF NOT EXISTS tithe_pool_entries_agency_date
  ON public.tithe_pool_entries (agency_id, entry_date);

COMMENT ON TABLE public.tithe_pool_entries IS
  'Money going INTO the tithe pool: automatic set-asides from income, plus any hand-entered adjustment. Money coming out is ledger.tithe_draw_amount, not a row here.';


-- ── what has been given out of it ────────────────────────────────────────────
ALTER TABLE public.ledger
  ADD COLUMN IF NOT EXISTS tithe_draw_amount numeric(14,2);

ALTER TABLE public.ledger
  DROP CONSTRAINT IF EXISTS ledger_tithe_draw_amount_positive;
ALTER TABLE public.ledger
  ADD CONSTRAINT ledger_tithe_draw_amount_positive
  CHECK (tithe_draw_amount IS NULL OR tithe_draw_amount > 0);

CREATE INDEX IF NOT EXISTS ledger_tithe_draws
  ON public.ledger (agency_id, entry_date)
  WHERE tithe_draw_amount IS NOT NULL;

COMMENT ON COLUMN public.ledger.tithe_draw_amount IS
  'How much of this transaction comes out of the tithe pool. Empty means none. Set it on any transaction regardless of which expense account it is filed under, so a marketing charge can still count against giving.';
