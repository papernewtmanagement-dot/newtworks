-- =====================================================================
-- Phase 4g: Flatten personal P&L + rename per Peter's feedback
-- 1. Rename PN-HOME-OFFICE-SECURITY -> "Security" (Peter said "security" not "home office security")
-- 2. Rename PERSONAL-8999 + PERSONAL-9999 both to just "Unclassified"
--    (account_type disambiguates: one shows under Income section, one under Expense)
-- 3. Modify get_pnl_history_own_only to flatten: section = INITCAP(account_type)
--    when the leaf has no parent. Agency accounts with real parent chains still get root_name.
-- =====================================================================

UPDATE public.chart_of_accounts
   SET account_name = 'Security'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND chart_namespace = 'active'
   AND account_code = 'PN-HOME-OFFICE-SECURITY';

UPDATE public.chart_of_accounts
   SET account_name = 'Unclassified'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND chart_namespace = 'active'
   AND account_code IN ('PERSONAL-8999','PERSONAL-9999');

CREATE OR REPLACE FUNCTION public.get_pnl_history_own_only(p_entity_id uuid)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
  WITH RECURSIVE ancestry AS (
    SELECT id AS leaf_id, id AS cur_id, account_name, parent_account_id
    FROM public.chart_of_accounts
    UNION ALL
    SELECT a.leaf_id, p.id, p.account_name, p.parent_account_id
    FROM public.chart_of_accounts p
    JOIN ancestry a ON a.parent_account_id = p.id
  ),
  coa_root AS (
    SELECT leaf_id, account_name AS root_name
    FROM ancestry WHERE parent_account_id IS NULL
  ),
  post_cutover AS (
    SELECT
      EXTRACT(year FROM je.entry_date)::int AS year,
      EXTRACT(month FROM je.entry_date)::int AS month,
      coa.account_name,
      coa.account_type::text AS account_type,
      COALESCE(NULLIF(r.root_name, coa.account_name), INITCAP(coa.account_type::text)) AS section,
      CASE
        WHEN coa.account_type = 'income' AND je.source LIKE 'historical_import%' THEN SUM(jl.debit) - SUM(jl.credit)
        WHEN coa.account_type = 'income' THEN SUM(jl.credit) - SUM(jl.debit)
        WHEN coa.account_type = 'expense' THEN SUM(jl.debit) - SUM(jl.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.journal_lines jl
    JOIN public.journal_entries je ON je.id = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    LEFT JOIN coa_root r ON r.leaf_id = coa.id
    WHERE coa.account_type IN ('income','expense') AND je.business_entity_id = p_entity_id
    GROUP BY je.entry_date, je.source, coa.id, coa.account_name, coa.account_type, r.root_name
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type, COALESCE(py.section, 'Uncategorized') AS section, py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense') AND py.business_entity_id = p_entity_id
  ),
  combined AS (
    SELECT year, month, account_name, account_type, section, amount FROM post_cutover
    UNION ALL
    SELECT year, month, account_name, account_type, section, amount FROM pre_cutover
  )
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM combined GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;
