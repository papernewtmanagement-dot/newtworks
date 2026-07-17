-- ================================================================
-- get_pnl_history v2 — adds `section` field for parent-category grouping.
-- Pre-cutover (prior_year_pl): uses the QBO section ("0001 ADMINISTRATION",
-- "0002 TEAM", etc.) which lives in account_subtype after the UNION.
-- Post-cutover (journal_entries): chart_of_accounts.account_subtype is
-- unfriendly split-label garbage ("task3_split_label/occ=130"), so we
-- override those to "Z Post-6/30 ledger" (Z prefix keeps it at bottom
-- of alphabetical section list).
-- ================================================================
CREATE OR REPLACE FUNCTION public.get_pnl_history()
RETURNS json
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
  WITH src AS (
    SELECT
      year::int          AS year,
      month::int         AS month,
      account_name       AS account_name,
      account_type::text AS account_type,
      CASE
        WHEN account_subtype IS NULL
          OR account_subtype LIKE 'task3_split_label%'
          OR account_subtype LIKE 'task%_split%'
          THEN 'Z Post-6/30 ledger'
        ELSE account_subtype
      END AS section,
      amount
    FROM public.v_income_statement
  )
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM src
    GROUP BY year, month, account_name, account_type, section
  ) t;
$$;

GRANT EXECUTE ON FUNCTION public.get_pnl_history() TO authenticated, anon;
