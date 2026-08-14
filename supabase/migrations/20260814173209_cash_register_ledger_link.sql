ALTER TABLE public.ledger
  ADD COLUMN IF NOT EXISTS cash_register_id uuid
    REFERENCES public.cash_register_preliminary(id);

CREATE INDEX IF NOT EXISTS idx_ledger_cash_register_id
  ON public.ledger(cash_register_id) WHERE cash_register_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ledger_unclaimed_register
  ON public.ledger(entry_date) WHERE cash_register_id IS NOT NULL
                                 AND statement_id IS NULL;
