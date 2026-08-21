CREATE OR REPLACE VIEW v_balance_sheet_anchored AS
WITH
-- Post-4/30 GL movement on the balance-sheet accounts themselves (banks, cards, A/P)
post_activity AS (
  SELECT coa.account_code,
         ROUND(SUM(
           CASE WHEN coa.account_type IN ('asset','expense')
                THEN jl.debit - jl.credit
                ELSE jl.credit - jl.debit
           END
         )::numeric, 2) AS activity
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND je.entry_date > '2026-04-30'
    AND coa.account_type IN ('asset','liability','equity')
  GROUP BY coa.account_code
),
-- Post-4/30 net income (income - expense) rolls into equity
post_net_income AS (
  SELECT ROUND(SUM(
           CASE WHEN coa.account_type = 'income'  THEN jl.credit - jl.debit
                WHEN coa.account_type = 'expense' THEN -(jl.debit - jl.credit)
                ELSE 0 END
         )::numeric, 2) AS ni
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND je.entry_date > '2026-04-30'
    AND coa.account_type IN ('income','expense')
)
SELECT
  ob.agency_id,
  ob.account_code,
  ob.account_name,
  ob.account_type,
  ob.opening_balance AS anchor_0430,
  COALESCE(pa.activity, 0) AS activity_since_0430,
  ROUND((ob.opening_balance + COALESCE(pa.activity, 0))::numeric, 2) AS balance_current
FROM opening_balances ob
LEFT JOIN post_activity pa ON pa.account_code = ob.account_code
WHERE ob.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND ob.as_of_date = '2026-04-30'

UNION ALL

-- Synthetic line: post-4/30 net income added to equity (keeps the sheet balanced as May activity posts)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'BCC-NI-POST0430',
  'Net Income (May 1 forward, BCC GL)',
  'equity',
  0::numeric,
  COALESCE((SELECT ni FROM post_net_income), 0),
  COALESCE((SELECT ni FROM post_net_income), 0);
