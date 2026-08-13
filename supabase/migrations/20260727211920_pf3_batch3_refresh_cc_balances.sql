-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-27 21:19:20 UTC (ledger name: pf3_batch3_refresh_cc_balances) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260727211920.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Refresh credit_accounts.current_balance to reflect anchor + all recorded txns
-- After batch 3 ingest: 3208 and 8847 had stale/zero stored balances; 1247 stored was pre-July payment
UPDATE public.credit_accounts ca
SET current_balance = sub.new_bal,
    updated_at = NOW()
FROM (
  SELECT ca.id,
    COALESCE(asb.balance, 0) + COALESCE((
      SELECT SUM(ct.amount) FROM public.credit_transactions ct WHERE ct.credit_account_id = ca.id
    ), 0) AS new_bal
  FROM public.credit_accounts ca
  LEFT JOIN public.account_starting_balances asb
    ON asb.agency_id = ca.agency_id
    AND asb.account_type = 'credit_card'
    AND asb.account_last4 = ca.account_number_last4
  WHERE ca.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND ca.account_number_last4 IN ('3208','7435','8847','1006','1247')
) sub
WHERE ca.id = sub.id;

-- Return the new values
SELECT account_number_last4, account_name, current_balance
FROM public.credit_accounts
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_number_last4 IN ('3208','7435','8847','1006','1247')
ORDER BY account_number_last4;
