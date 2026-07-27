-- Add statement_close_day (1-31, day of month statement closes; capped at end-of-month if short).
-- Nullable — Peter fills in as statements land or via UI.

ALTER TABLE public.bank_accounts
  ADD COLUMN IF NOT EXISTS statement_close_day smallint
    CHECK (statement_close_day IS NULL OR (statement_close_day BETWEEN 1 AND 31));

ALTER TABLE public.credit_accounts
  ADD COLUMN IF NOT EXISTS statement_close_day smallint
    CHECK (statement_close_day IS NULL OR (statement_close_day BETWEEN 1 AND 31));

UPDATE public.bank_accounts SET statement_close_day = 22 WHERE account_number_last4 = '0353' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.bank_accounts SET statement_close_day = 24 WHERE account_number_last4 = '6730' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.bank_accounts SET statement_close_day =  8 WHERE account_number_last4 = '2545' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.bank_accounts SET statement_close_day = 25 WHERE account_number_last4 = '6755' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.bank_accounts SET statement_close_day = 31 WHERE account_number_last4 = '6596' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.bank_accounts SET statement_close_day = 31 WHERE account_number_last4 = '3977' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.bank_accounts SET statement_close_day = 23 WHERE account_number_last4 IS NULL AND account_name = 'US Bank - Expenses' AND agency_id='126794dd-25ff-47d2-a436-724499733365';

UPDATE public.credit_accounts SET statement_close_day =  8 WHERE account_number_last4 = '8847' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.credit_accounts SET statement_close_day = 27 WHERE account_number_last4 = '3208' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.credit_accounts SET statement_close_day = 28 WHERE account_number_last4 = '7435' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.credit_accounts SET statement_close_day = 15 WHERE account_number_last4 = '1006' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
UPDATE public.credit_accounts SET statement_close_day =  5 WHERE account_number_last4 = '1247' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
