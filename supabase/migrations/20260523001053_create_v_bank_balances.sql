
CREATE OR REPLACE VIEW v_bank_balances AS
WITH ledger AS (
  SELECT
    je.agency_id,
    coa.id            AS chart_account_id,
    coa.account_code,
    coa.account_name,
    -- Asset convention: positive = funds on hand.
    round(sum(jl.debit) - sum(jl.credit), 2) AS balance_total,
    round(sum(jl.debit) FILTER (WHERE je.entry_date <= '2026-04-30')
        - sum(jl.credit) FILTER (WHERE je.entry_date <= '2026-04-30'), 2) AS balance_anchor_0430,
    round(sum(jl.debit) FILTER (WHERE je.entry_date > '2026-04-30')
        - sum(jl.credit) FILTER (WHERE je.entry_date > '2026-04-30'), 2) AS activity_since_anchor,
    max(je.entry_date) AS last_entry_date,
    count(DISTINCT je.id) AS entry_count
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  WHERE coa.account_code IN ('COA-001','COA-024','COA-002','COA-003','COA-004','COA-005','COA-006','COA-007')
  GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name
)
SELECT
  agency_id,
  chart_account_id,
  account_code,
  account_name,
  COALESCE(balance_anchor_0430, 0)   AS balance_anchor_0430,
  COALESCE(activity_since_anchor, 0)  AS activity_since_anchor,
  COALESCE(balance_total, 0)          AS current_balance_derived,
  last_entry_date,
  entry_count,
  CASE WHEN COALESCE(balance_total,0) < 0 THEN true ELSE false END AS needs_review
FROM ledger;

