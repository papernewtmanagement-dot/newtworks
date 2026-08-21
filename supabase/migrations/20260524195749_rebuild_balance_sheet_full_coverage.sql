CREATE OR REPLACE VIEW v_balance_sheet_anchored AS
WITH agency AS (SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid AS id),
-- All post-4/30 activity on balance-sheet accounts (asset/liability/equity)
post_activity AS (
  SELECT coa.account_code, MAX(coa.account_name) AS account_name, coa.account_type,
         ROUND(SUM(CASE WHEN coa.account_type IN ('asset','expense')
                        THEN jl.debit - jl.credit
                        ELSE jl.credit - jl.debit END)::numeric,2) AS activity
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id=je.id
  JOIN chart_of_accounts coa ON coa.id=jl.account_id, agency
  WHERE je.agency_id=agency.id
    AND je.entry_date > '2026-04-30'
    AND coa.account_type IN ('asset','liability','equity')
  GROUP BY coa.account_code, coa.account_type
),
-- Post-4/30 net income -> equity
post_net_income AS (
  SELECT ROUND(SUM(CASE WHEN coa.account_type='income'  THEN jl.credit - jl.debit
                        WHEN coa.account_type='expense' THEN -(jl.debit - jl.credit)
                        ELSE 0 END)::numeric,2) AS ni
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id=je.id
  JOIN chart_of_accounts coa ON coa.id=jl.account_id, agency
  WHERE je.agency_id=agency.id
    AND je.entry_date > '2026-04-30'
    AND coa.account_type IN ('income','expense')
),
-- Every account that appears in EITHER the anchor OR post-4/30 activity (FULL coverage)
codes AS (
  SELECT account_code FROM opening_balances, agency
    WHERE agency_id=agency.id AND as_of_date='2026-04-30'
  UNION
  SELECT account_code FROM post_activity
)
SELECT
  agency.id AS agency_id,
  c.account_code,
  COALESCE(ob.account_name, pa.account_name)  AS account_name,
  COALESCE(ob.account_type, pa.account_type)  AS account_type,
  COALESCE(ob.opening_balance, 0)             AS anchor_0430,
  COALESCE(pa.activity, 0)                    AS activity_since_0430,
  ROUND((COALESCE(ob.opening_balance,0) + COALESCE(pa.activity,0))::numeric,2) AS balance_current
FROM codes c
CROSS JOIN agency
LEFT JOIN opening_balances ob
  ON ob.account_code=c.account_code AND ob.agency_id=agency.id AND ob.as_of_date='2026-04-30'
LEFT JOIN post_activity pa ON pa.account_code=c.account_code

UNION ALL

SELECT agency.id, 'BCC-NI-POST0430', 'Net Income (May 1 forward, BCC GL)', 'equity',
       0::numeric,
       COALESCE((SELECT ni FROM post_net_income),0),
       COALESCE((SELECT ni FROM post_net_income),0)
FROM agency;
