
-- Chase Marketing 7762 + 7770 = two physical cards on one account (one monthly stmt).
-- Peter directive 2026-07-28: use 7762 as the single card record, store 7770 in a new
-- alternate_last4 column, point every transaction from either card at the same record.
-- Frontend Financials module will surface alternate_last4 alongside primary last4.
-- GL side (37 journal_lines on COA-012 vs 7 on COA-011) NOT touched this migration —
-- tangled with the 241-JE-pending-classification workflow that is on hold.

-- 1) New column on credit_accounts
ALTER TABLE public.credit_accounts
  ADD COLUMN IF NOT EXISTS alternate_last4 text;

COMMENT ON COLUMN public.credit_accounts.alternate_last4 IS
  'Alternate physical card last-4 when the account has more than one physical card, both mapping to this same record. Example: Chase Marketing has 7762 primary + 7770 alternate.';

-- 2) Attach 7770 as the alternate on the surviving Marketing record (last4=7762)
UPDATE public.credit_accounts
   SET alternate_last4 = '7770',
       updated_at = NOW()
 WHERE id = '37c0a92a-66b8-42d4-a602-cd36734f375f';

-- 3) Move 11 credit_transactions from Marketing 2 -> Marketing 1
UPDATE public.credit_transactions
   SET credit_account_id = '37c0a92a-66b8-42d4-a602-cd36734f375f'
 WHERE credit_account_id = '4d1af9e2-dff4-4a48-aec5-5c13ed7a5205';

-- 4) Set current_balance to latest known statement close ($3,923.55 addressed to 7762)
UPDATE public.credit_accounts
   SET current_balance = 3923.55,
       updated_at = NOW()
 WHERE id = '37c0a92a-66b8-42d4-a602-cd36734f375f';

-- 5) Remove stale ledger_snapshot statement_balances for both COA codes.
-- Real statements will be inserted during the 6-file Chase ingest that follows.
DELETE FROM public.statement_balances
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('COA-011','COA-012')
   AND source = 'ledger_snapshot_20260630';

-- 6) Delete the Marketing 2 credit_account row (delete_means_delete op-rule)
DELETE FROM public.credit_accounts
 WHERE id = '4d1af9e2-dff4-4a48-aec5-5c13ed7a5205';

