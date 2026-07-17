-- ================================================================
-- v_income_statement now UNIONs prior_year_pl for pre-cutover periods.
-- Peter's directive 2026-07-16: kill the standalone Prior Years tab
-- and let historical P&L flow into the current P&L annual grain.
-- Post-cutover ledger (journal_entries) continues to feed post-6/30
-- rows. Pre-cutover P&L (2019 – May 2026) comes from prior_year_pl.
-- Data is naturally disjoint by date (prior_year_pl ends ~5/11/2026,
-- journal_entries starts 7/3/2026) so UNION ALL is safe — no dedup
-- collisions.
-- ================================================================
CREATE OR REPLACE VIEW public.v_income_statement AS
-- POST-CUTOVER: journal_entries + journal_lines
SELECT
  je.agency_id,
  EXTRACT(year  FROM je.entry_date)::integer                       AS period_year,
  EXTRACT(month FROM je.entry_date)::integer                       AS period_month,
  EXTRACT(year  FROM je.entry_date)::integer                       AS year,
  EXTRACT(month FROM je.entry_date)::integer                       AS month,
  to_char(je.entry_date::timestamp with time zone, 'YYYY-MM'::text) AS period,
  date_trunc('month', je.entry_date::timestamp with time zone)::date AS period_date,
  coa.id                                                          AS account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.account_subtype,
  sum(jl.debit)                                                   AS total_debit,
  sum(jl.credit)                                                  AS total_credit,
  CASE
    WHEN coa.account_type = 'income'  AND je.source LIKE 'historical_import%' THEN sum(jl.debit)  - sum(jl.credit)
    WHEN coa.account_type = 'income'                                           THEN sum(jl.credit) - sum(jl.debit)
    WHEN coa.account_type = 'expense'                                          THEN sum(jl.debit)  - sum(jl.credit)
    ELSE 0::numeric
  END                                                             AS amount
FROM journal_lines jl
JOIN journal_entries    je  ON je.id  = jl.journal_entry_id
JOIN chart_of_accounts  coa ON coa.id = jl.account_id
WHERE coa.account_type IN ('income', 'expense')
GROUP BY je.agency_id, je.entry_date, je.source,
         coa.id, coa.account_code, coa.account_name,
         coa.account_type, coa.account_subtype

UNION ALL

-- PRE-CUTOVER: prior_year_pl (QBO historical P&L, 2019 – May 2026).
-- account_name comes verbatim from prior_year_pl (leading QBO codes
-- preserved on purpose so Peter's audit trail matches the source PDFs).
SELECT
  py.agency_id,
  py.period_year                                                  AS period_year,
  py.period_month                                                 AS period_month,
  py.period_year                                                  AS year,
  py.period_month                                                 AS month,
  to_char(py.period_start::timestamp with time zone, 'YYYY-MM'::text) AS period,
  date_trunc('month', py.period_start::timestamp with time zone)::date AS period_date,
  NULL::uuid                                                      AS account_id,
  NULL::text                                                      AS account_code,
  py.account_name,
  LOWER(py.section_type)                                          AS account_type,  -- 'Income'/'Expense' → 'income'/'expense'
  py.section                                                      AS account_subtype, -- QBO section (e.g. "0002 TEAM") lives here for grouping later if wanted
  NULL::numeric                                                   AS total_debit,
  NULL::numeric                                                   AS total_credit,
  py.amount
FROM prior_year_pl py
WHERE LOWER(py.section_type) IN ('income', 'expense');
