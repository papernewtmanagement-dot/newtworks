-- Peter directive 2026-07-28: 'USBank GN Personal Card' + $9,434.85 balance does not exist.
-- Both the credit_accounts row (e36d7360) and its backing chart_of_accounts row (COA-025)
-- carry zero references (0 credit_transactions, 0 statement_balances, 0 journal_lines).
-- Full delete on both.

DELETE FROM public.credit_accounts
 WHERE id = 'e36d7360-03bc-4d01-be62-e50ec1d8471c';

DELETE FROM public.chart_of_accounts
 WHERE id = '1d22ded2-9031-48a3-9169-b40192e3792b';
