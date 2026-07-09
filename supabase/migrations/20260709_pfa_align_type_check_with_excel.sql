-- Align pfa_transactions.transaction_type CHECK with Peter's Excel ledger terminology.
-- Excel uses "Misc Withdrawal" not "Other Withdrawal" — preserve Peter's labels.
ALTER TABLE public.pfa_transactions
  DROP CONSTRAINT IF EXISTS pfa_transactions_transaction_type_check;

ALTER TABLE public.pfa_transactions
  ADD CONSTRAINT pfa_transactions_transaction_type_check
  CHECK (transaction_type IN (
    'Deposit',
    'State Farm EFT',
    'Bank Service Fee',
    'Personal Deposit',
    'Returned Check',
    'NSF/Overdraft Fee',
    'Interest',
    'Misc Withdrawal',
    'Other Credit'
  ));
