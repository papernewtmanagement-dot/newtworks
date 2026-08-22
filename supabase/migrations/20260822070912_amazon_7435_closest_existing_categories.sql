
-- Peter 2026-08-18: use closest-fitting EXISTING PaperNewt accounts, no new accounts.
-- Bulk care-package purchases stay in 6400 Advertising & Marketing (closest existing fit
-- for customer goodwill/retention spend). Only the outliers move.

-- 1. Office/cleaning supplies Alvi identified -> 6910 Office Supplies & Expense
UPDATE ledger l
SET original_account_id = COALESCE(l.original_account_id, l.account_id),
    original_account_code = COALESCE(l.original_account_code, '6400'),
    original_account_name = COALESCE(l.original_account_name, 'Advertising & Marketing'),
    account_id = (SELECT id FROM chart_of_accounts
                  WHERE account_code='6910' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
    classified_by = 'rule', classified_at = now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id = st.id AND st.account_id = a.id AND cur.id = l.account_id
  AND a.account_number_last4 = '7435' AND cur.account_code = '6400'
  AND l.description ~* '\yamazon\y|\yamzn\y'
  AND (
    (l.entry_date='2026-06-01' AND GREATEST(l.debit,l.credit)=57.37) OR  -- printer toner
    (l.entry_date='2026-06-26' AND GREATEST(l.debit,l.credit)=15.58) OR  -- mop heads
    (l.entry_date='2026-07-24' AND GREATEST(l.debit,l.credit)=19.47)     -- printer paper
  );

-- 2. Alvi's birthday gift -> 6160 Employee Relations & Meals (she is active staff)
UPDATE ledger l
SET original_account_id = COALESCE(l.original_account_id, l.account_id),
    original_account_code = COALESCE(l.original_account_code, '6400'),
    original_account_name = COALESCE(l.original_account_name, 'Advertising & Marketing'),
    account_id = (SELECT id FROM chart_of_accounts
                  WHERE account_code='6160' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
    classified_by = 'rule', classified_at = now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id = st.id AND st.account_id = a.id AND cur.id = l.account_id
  AND a.account_number_last4 = '7435' AND cur.account_code = '6400'
  AND l.description ~* '\yamazon\y|\yamzn\y'
  AND l.entry_date='2026-01-02' AND GREATEST(l.debit,l.credit)=102.31;

-- 3. Lines Alvi named for non-staff family members -> 3050 S-Corp Distributions.
--    No expense account fits a gift to a non-employee, and 3050 already exists.
UPDATE ledger l
SET original_account_id = COALESCE(l.original_account_id, l.account_id),
    original_account_code = COALESCE(l.original_account_code, '6400'),
    original_account_name = COALESCE(l.original_account_name, 'Advertising & Marketing'),
    account_id = (SELECT id FROM chart_of_accounts
                  WHERE account_code='3050' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
    classified_by = 'rule', classified_at = now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id = st.id AND st.account_id = a.id AND cur.id = l.account_id
  AND a.account_number_last4 = '7435' AND cur.account_code = '6400'
  AND l.description ~* '\yamazon\y|\yamzn\y'
  AND (
    (l.entry_date='2026-01-05' AND GREATEST(l.debit,l.credit)=27.05) OR   -- nunchucks, Max
    (l.entry_date='2026-02-21' AND GREATEST(l.debit,l.credit)=24.83) OR   -- Peter shampoo/conditioner
    (l.entry_date='2026-01-25' AND GREATEST(l.debit,l.credit)=22.99) OR   -- Kip vitamins
    (l.entry_date='2026-02-05' AND GREATEST(l.debit,l.credit)=32.46) OR   -- Becca nail lamp refund
    (l.entry_date='2026-02-05' AND GREATEST(l.debit,l.credit)=32.06)      -- Becca books refund
  );

