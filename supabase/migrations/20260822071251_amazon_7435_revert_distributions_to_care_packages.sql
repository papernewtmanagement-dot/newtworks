
-- Peter 2026-08-18: these are not distributions. Alvi's notes attached people's names to
-- them, but they were not bought for anyone in particular -- they are care-package stock
-- like the rest. Move back to 6400 and record the item itself, not a person's name.

UPDATE ledger l
SET account_id = (SELECT id FROM chart_of_accounts
                  WHERE account_code='6400' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
    memo = CASE
      WHEN l.entry_date='2026-01-05' AND GREATEST(l.debit,l.credit)=27.05 THEN 'Nunchucks'
      WHEN l.entry_date='2026-02-21' AND GREATEST(l.debit,l.credit)=24.83 THEN 'Shampoo and conditioner'
      WHEN l.entry_date='2026-01-25' AND GREATEST(l.debit,l.credit)=22.99 THEN 'Vitamins'
      WHEN l.entry_date='2026-02-05' AND GREATEST(l.debit,l.credit)=32.46 THEN 'Refund - nail lamp'
      WHEN l.entry_date='2026-02-05' AND GREATEST(l.debit,l.credit)=32.06 THEN 'Refund - books'
      ELSE l.memo END,
    classified_by = 'rule', classified_at = now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id = st.id AND st.account_id = a.id AND cur.id = l.account_id
  AND a.account_number_last4 = '7435' AND cur.account_code = '3050'
  AND l.description ~* '\yamazon\y|\yamzn\y';

