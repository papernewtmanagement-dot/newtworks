-- Refresh credit_accounts.current_balance to reflect anchor + all recorded txns.
-- Post pf3_batch3 ingest: 3208 and 8847 had stale/zero stored balances; 1247 stored was pre-July payment.
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
