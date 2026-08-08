DROP VIEW public.v_income_statement;

CREATE VIEW public.v_income_statement AS
SELECT
  l.agency_id,
  coa.business_entity_id,
  EXTRACT(year  FROM l.entry_date)::integer                       AS period_year,
  EXTRACT(month FROM l.entry_date)::integer                       AS period_month,
  EXTRACT(year  FROM l.entry_date)::integer                       AS year,
  EXTRACT(month FROM l.entry_date)::integer                       AS month,
  to_char(l.entry_date::timestamp with time zone, 'YYYY-MM'::text) AS period,
  date_trunc('month', l.entry_date::timestamp with time zone)::date AS period_date,
  coa.id                                                          AS account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.account_subtype,
  sum(l.debit)                                                    AS total_debit,
  sum(l.credit)                                                   AS total_credit,
  CASE
    WHEN coa.account_type = 'income'  AND l.source LIKE 'historical_import%' THEN sum(l.debit)  - sum(l.credit)
    WHEN coa.account_type = 'income'                                          THEN sum(l.credit) - sum(l.debit)
    WHEN coa.account_type = 'expense'                                         THEN sum(l.debit)  - sum(l.credit)
    ELSE 0::numeric
  END                                                             AS amount
FROM ledger l
JOIN chart_of_accounts coa ON coa.id = l.account_id
WHERE coa.account_type IN ('income', 'expense')
  AND l.entry_date >= '2026-01-01'
GROUP BY l.agency_id, coa.business_entity_id, l.entry_date, l.source,
         coa.id, coa.account_code, coa.account_name,
         coa.account_type, coa.account_subtype

UNION ALL

SELECT
  py.agency_id,
  py.business_entity_id,
  py.period_year                                                  AS period_year,
  py.period_month                                                 AS period_month,
  py.period_year                                                  AS year,
  py.period_month                                                 AS month,
  to_char(py.period_start::timestamp with time zone, 'YYYY-MM'::text) AS period,
  date_trunc('month', py.period_start::timestamp with time zone)::date AS period_date,
  NULL::uuid                                                      AS account_id,
  NULL::text                                                      AS account_code,
  py.account_name,
  LOWER(py.section_type)                                          AS account_type,
  py.section                                                      AS account_subtype,
  NULL::numeric                                                   AS total_debit,
  NULL::numeric                                                   AS total_credit,
  py.amount
FROM prior_year_pl py
WHERE LOWER(py.section_type) IN ('income', 'expense');

ALTER VIEW public.v_income_statement SET (security_invoker = true);
REVOKE ALL ON public.v_income_statement FROM anon, PUBLIC;
GRANT SELECT ON public.v_income_statement TO authenticated;
