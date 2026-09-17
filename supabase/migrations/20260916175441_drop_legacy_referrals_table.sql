-- Referral detail now lives on quote_log and sales_log.
-- Nothing reads this table: no views, no foreign keys, no functions.
DROP TABLE IF EXISTS public.referrals;
