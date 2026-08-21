
CREATE OR REPLACE VIEW v_card_balances AS
WITH ledger AS (
  SELECT
    je.agency_id,
    ca.id            AS credit_account_id,
    ca.account_name,
    ca.institution,
    ca.chart_account_id,
    -- Statement-style balance: amount owed reads positive.
    -- legacy source books these debit-positive, so debit - credit = balance owed.
    round(sum(jl.debit) - sum(jl.credit), 2) AS balance_total,
    round(sum(jl.debit) FILTER (WHERE je.entry_date <= '2026-04-30')
        - sum(jl.credit) FILTER (WHERE je.entry_date <= '2026-04-30'), 2) AS balance_anchor_0430,
    round(sum(jl.debit) FILTER (WHERE je.entry_date > '2026-04-30')
        - sum(jl.credit) FILTER (WHERE je.entry_date > '2026-04-30'), 2) AS activity_since_anchor,
    max(je.entry_date) AS last_entry_date,
    count(DISTINCT je.id) AS entry_count
  FROM credit_accounts ca
  JOIN chart_of_accounts coa ON coa.id = ca.chart_account_id
  JOIN journal_lines jl ON jl.account_id = coa.id
  JOIN journal_entries je ON je.id = jl.journal_entry_id AND je.agency_id = ca.agency_id
  GROUP BY je.agency_id, ca.id, ca.account_name, ca.institution, ca.chart_account_id
)
SELECT
  agency_id,
  credit_account_id,
  account_name,
  institution,
  chart_account_id,
  COALESCE(balance_anchor_0430, 0)  AS balance_anchor_0430,
  COALESCE(activity_since_anchor, 0) AS activity_since_anchor,
  COALESCE(balance_total, 0)         AS current_balance_derived,
  last_entry_date,
  entry_count,
  -- Flag accounts that need CPA review: negative card balances are unusual
  CASE WHEN COALESCE(balance_total,0) < 0 THEN true ELSE false END AS needs_review
FROM ledger;

