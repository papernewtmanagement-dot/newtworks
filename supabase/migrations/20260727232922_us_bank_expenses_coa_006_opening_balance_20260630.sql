-- Seed opening_balances for COA-006 at the anchor date using the 26-06 statement close balance.
-- 26-06 closed 6/24 at $75,039.22; zero journal activity for COA-006 between 6/25 and 6/30
-- so the 6/30 anchor = 6/24 balance. Closes the Balance Sheet gap for this account.

INSERT INTO public.opening_balances
  (agency_id, as_of_date, account_code, account_name, account_type, opening_balance, source, business_entity_id)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   '2026-06-30',
   'COA-006',
   'US Bank - Expenses',
   'asset',
   75039.22,
   'us_bank_expenses_stmt_26-06',
   'b2222222-2222-2222-2222-222222222222'::uuid);
