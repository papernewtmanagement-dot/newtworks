CREATE OR REPLACE VIEW v_income_statement AS
SELECT
  je.agency_id,
  EXTRACT(YEAR  FROM je.entry_date)::INT  AS period_year,
  EXTRACT(MONTH FROM je.entry_date)::INT  AS period_month,
  EXTRACT(YEAR  FROM je.entry_date)::INT  AS year,
  EXTRACT(MONTH FROM je.entry_date)::INT  AS month,
  TO_CHAR(je.entry_date, 'YYYY-MM')        AS period,
  DATE_TRUNC('month', je.entry_date)::DATE AS period_date,
  coa.id            AS account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.account_subtype,
  SUM(jl.debit)     AS total_debit,
  SUM(jl.credit)    AS total_credit,
  CASE
    WHEN coa.account_type = 'income'  THEN SUM(jl.credit) - SUM(jl.debit)
    WHEN coa.account_type = 'expense' THEN SUM(jl.debit)  - SUM(jl.credit)
    ELSE 0
  END AS amount
FROM journal_lines jl
JOIN journal_entries  je  ON je.id  = jl.journal_entry_id
JOIN chart_of_accounts coa ON coa.id = jl.account_id
WHERE coa.account_type IN ('income', 'expense')
GROUP BY
  je.agency_id, je.entry_date, coa.id,
  coa.account_code, coa.account_name, coa.account_type, coa.account_subtype;

GRANT SELECT ON v_income_statement TO anon, authenticated;

CREATE OR REPLACE VIEW v_balance_sheet AS
SELECT
  jl.agency_id,
  coa.id            AS account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.account_subtype,
  SUM(jl.debit)     AS total_debit,
  SUM(jl.credit)    AS total_credit,
  CASE
    WHEN coa.account_type = 'asset'                 THEN SUM(jl.debit)  - SUM(jl.credit)
    WHEN coa.account_type IN ('liability','equity') THEN SUM(jl.credit) - SUM(jl.debit)
    ELSE 0
  END AS balance,
  MAX(je.entry_date) AS last_activity_date
FROM journal_lines jl
JOIN journal_entries  je  ON je.id  = jl.journal_entry_id
JOIN chart_of_accounts coa ON coa.id = jl.account_id
WHERE coa.account_type IN ('asset', 'liability', 'equity')
GROUP BY
  jl.agency_id, coa.id,
  coa.account_code, coa.account_name, coa.account_type, coa.account_subtype;

GRANT SELECT ON v_balance_sheet TO anon, authenticated;
