
-- Peter 2026-08-18: classify the Amazon lines Alvi identified on the AmEx (1003) and the
-- agency US Bank card (3447), using existing accounts only.

-- ============ CARD 1003 — AmEx PaperNewt Discretionary (PaperNewt LLC) ============

-- Snacks and drinks for the office -> Employee Relations & Meals
UPDATE ledger l SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='6160' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
  original_account_code = COALESCE(l.original_account_code, cur.account_code),
  original_account_name = COALESCE(l.original_account_name, cur.account_name),
  memo = CASE WHEN l.credit > 0 THEN 'Refund - damaged office snacks/drinks' ELSE 'Office snacks' END,
  classification_status='classified', classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='1003' AND l.description ~* '\yamazon\y|\yamzn\y'
  AND ((l.entry_date='2026-02-18' AND GREATEST(l.debit,l.credit) IN (50.64, 8.65))
    OR (l.entry_date='2026-04-15' AND GREATEST(l.debit,l.credit)=65.65)
    OR (l.entry_date='2026-05-12' AND GREATEST(l.debit,l.credit)=24.50)
    OR (l.entry_date='2026-05-22' AND GREATEST(l.debit,l.credit)=27.99));

-- HVAC and air purifier filters -> Repairs & Maintenance
UPDATE ledger l SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='6240' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
  original_account_code = COALESCE(l.original_account_code, cur.account_code),
  original_account_name = COALESCE(l.original_account_name, cur.account_name),
  memo = CASE WHEN l.entry_date='2026-02-20' THEN 'HVAC filters' ELSE 'Air purifier filters' END,
  classification_status='classified', classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='1003' AND l.description ~* '\yamazon\y|\yamzn\y'
  AND ((l.entry_date='2026-02-20' AND GREATEST(l.debit,l.credit)=31.24)
    OR (l.entry_date='2026-02-21' AND GREATEST(l.debit,l.credit)=27.66));

-- First aid stock, office slippers, lamp, shakers, flashlight -> Office Supplies & Expense
UPDATE ledger l SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='6910' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
  original_account_code = COALESCE(l.original_account_code, cur.account_code),
  original_account_name = COALESCE(l.original_account_name, cur.account_name),
  memo = CASE
    WHEN GREATEST(l.debit,l.credit) IN (16.36,19.31,44.16) THEN 'Electrolyte powder (first aid stock)'
    WHEN GREATEST(l.debit,l.credit)=20.35 THEN 'Vitamin D (first aid stock)'
    WHEN GREATEST(l.debit,l.credit)=29.98 THEN 'Cold medicine (first aid stock)'
    WHEN GREATEST(l.debit,l.credit)=25.95 THEN 'Salt and pepper shakers'
    WHEN GREATEST(l.debit,l.credit)=38.95 THEN 'Spotlight flashlight'
    WHEN GREATEST(l.debit,l.credit)=43.25 THEN 'Office slippers'
    WHEN GREATEST(l.debit,l.credit)=43.28 THEN 'Refund - returned office slippers'
    WHEN GREATEST(l.debit,l.credit)=34.58 THEN 'Refund - returned lamp'
    ELSE l.memo END,
  classification_status='classified', classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='1003' AND l.description ~* '\yamazon\y|\yamzn\y'
  AND l.description NOT ILIKE '%prime%'
  AND ((l.entry_date='2026-01-09' AND GREATEST(l.debit,l.credit)=16.36)
    OR (l.entry_date='2026-01-23' AND GREATEST(l.debit,l.credit) IN (19.31,20.35))
    OR (l.entry_date='2026-02-03' AND GREATEST(l.debit,l.credit)=25.95)
    OR (l.entry_date='2026-02-05' AND GREATEST(l.debit,l.credit) IN (43.28,34.58))
    OR (l.entry_date='2026-02-21' AND GREATEST(l.debit,l.credit) IN (44.16,20.35))
    OR (l.entry_date='2026-03-27' AND GREATEST(l.debit,l.credit) IN (44.16,20.35))
    OR (l.entry_date='2026-04-07' AND GREATEST(l.debit,l.credit)=38.95)
    OR (l.entry_date='2026-04-13' AND GREATEST(l.debit,l.credit)=43.25)
    OR (l.entry_date='2026-06-13' AND GREATEST(l.debit,l.credit)=29.98));

-- ============ CARD 3447 — US Bank, Peter Story State Farm ============

-- Employee gifts, awards, and holiday gifts -> Employee Relations & Meals
UPDATE ledger l SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='6160' AND business_entity_id=(SELECT id FROM business_entities WHERE name='Peter Story State Farm')),
  original_account_code = COALESCE(l.original_account_code, cur.account_code),
  original_account_name = COALESCE(l.original_account_name, cur.account_name),
  memo = CASE
    WHEN l.entry_date IN ('2026-01-08','2026-01-09') THEN 'Refund - returned holiday gift'
    WHEN GREATEST(l.debit,l.credit)=66.06 THEN 'Employee gift - sword'
    WHEN GREATEST(l.debit,l.credit)=75.66 THEN 'Refund - returned employee award (wrong address)'
    WHEN GREATEST(l.debit,l.credit)=590.91 THEN 'Champions Circle rings (employee awards)'
    ELSE l.memo END,
  classification_status='classified', classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='3447' AND l.description ~* '\yamazon\y|\yamzn\y'
  AND ((l.entry_date='2026-01-08' AND GREATEST(l.debit,l.credit) IN (129.89,35.71))
    OR (l.entry_date='2026-01-09' AND GREATEST(l.debit,l.credit) IN (36.79,26.67,16.23))
    OR (l.entry_date='2026-03-25' AND GREATEST(l.debit,l.credit)=66.06)
    OR (l.entry_date='2026-04-02' AND GREATEST(l.debit,l.credit)=75.66)
    OR (l.entry_date='2026-05-30' AND GREATEST(l.debit,l.credit)=590.91));

-- Desk refund -> Furniture and Fixtures
UPDATE ledger l SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='1510' AND business_entity_id=(SELECT id FROM business_entities WHERE name='Peter Story State Farm')),
  original_account_code = COALESCE(l.original_account_code, cur.account_code),
  original_account_name = COALESCE(l.original_account_name, cur.account_name),
  memo = 'Refund - damaged desk',
  classification_status='classified', classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='3447' AND l.description ~* '\yamazon\y|\yamzn\y'
  AND l.entry_date='2026-02-14' AND GREATEST(l.debit,l.credit)=248.64;

-- iPad -> Office Equipment (asset, large enough to capitalize)
UPDATE ledger l SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='1500' AND business_entity_id=(SELECT id FROM business_entities WHERE name='Peter Story State Farm')),
  original_account_code = COALESCE(l.original_account_code, cur.account_code),
  original_account_name = COALESCE(l.original_account_name, cur.account_name),
  memo = 'iPad',
  classification_status='classified', classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='3447' AND l.description ~* '\yamazon\y|\yamzn\y'
  AND l.entry_date='2026-06-25' AND GREATEST(l.debit,l.credit)=1284.94;

-- Computer equipment and its refunds -> Computer Equipment & IT Support
UPDATE ledger l SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='6330' AND business_entity_id=(SELECT id FROM business_entities WHERE name='Peter Story State Farm')),
  original_account_code = COALESCE(l.original_account_code, cur.account_code),
  original_account_name = COALESCE(l.original_account_name, cur.account_name),
  memo = CASE WHEN l.credit > 0 THEN 'Refund - returned computer equipment' ELSE 'Computer equipment' END,
  classification_status='classified', classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='3447' AND l.description ~* '\yamazon\y|\yamzn\y'
  AND ((l.entry_date='2026-07-01' AND GREATEST(l.debit,l.credit)=211.56)
    OR (l.entry_date='2026-07-02' AND GREATEST(l.debit,l.credit) IN (113.10,62.37,86.37)));

-- Decorative items -> Office Supplies & Expense
UPDATE ledger l SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='6910' AND business_entity_id=(SELECT id FROM business_entities WHERE name='Peter Story State Farm')),
  original_account_code = COALESCE(l.original_account_code, cur.account_code),
  original_account_name = COALESCE(l.original_account_name, cur.account_name),
  memo = 'Decorative items',
  classification_status='classified', classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='3447' AND l.description ~* '\yamazon\y|\yamzn\y'
  AND ((l.entry_date='2026-04-09' AND GREATEST(l.debit,l.credit)=101.23)
    OR (l.entry_date='2026-04-12' AND GREATEST(l.debit,l.credit)=10.81));

-- Unidentified line Alvi could not trace -> Miscellaneous Expense, flagged in memo
UPDATE ledger l SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='6950' AND business_entity_id=(SELECT id FROM business_entities WHERE name='Peter Story State Farm')),
  original_account_code = COALESCE(l.original_account_code, cur.account_code),
  original_account_name = COALESCE(l.original_account_name, cur.account_name),
  memo = 'Unidentified Amazon charge - no matching order found',
  classification_status='classified', classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='3447' AND l.description ~* '\yamazon\y|\yamzn\y'
  AND l.entry_date='2026-04-20' AND GREATEST(l.debit,l.credit)=28.69;

