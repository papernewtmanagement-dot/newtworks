
-- Peter 2026-08-18: the "birthday gift" label on this line is unreliable, same naming
-- problem as the others. Item unknown. Filing with the rest of the card's Amazon spend
-- (6400) rather than leaving it in Employee Relations on the strength of a bad label.

UPDATE ledger l
SET account_id = (SELECT id FROM chart_of_accounts
                  WHERE account_code='6400' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
    memo = 'Amazon purchase - item not identified',
    classified_by = 'rule', classified_at = now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id = st.id AND st.account_id = a.id AND cur.id = l.account_id
  AND a.account_number_last4 = '7435' AND cur.account_code = '6160'
  AND l.description ~* '\yamazon\y|\yamzn\y'
  AND l.entry_date = '2026-01-02' AND GREATEST(l.debit,l.credit) = 102.31;

