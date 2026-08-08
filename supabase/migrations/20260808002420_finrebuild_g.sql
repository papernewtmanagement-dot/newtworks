-- Peter directive 2026-08-07: drop the tables superseded by `accounts` and `statements`.
-- CASCADE takes the dependent views with them; those are being rebuilt against the new tables.
DROP TABLE IF EXISTS public.bank_transactions CASCADE;
DROP TABLE IF EXISTS public.credit_transactions CASCADE;
DROP TABLE IF EXISTS public.bank_accounts CASCADE;
DROP TABLE IF EXISTS public.credit_accounts CASCADE;