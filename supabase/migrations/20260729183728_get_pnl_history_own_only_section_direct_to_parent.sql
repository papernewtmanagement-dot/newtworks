-- Peter directive 2026-07-29: get_pnl_history_own_only was dropping direct-to-parent
-- bookings (journal_lines against COA-019/020/021/022/031 root parents) and
-- cross-entity-orphan-COA bookings into the fallback "Expense" bucket via
-- NULLIF(r.root_name, coa.account_name). That's why "0001 ADMINISTRATION $36",
-- "0003 TEAM $300", "0004 MARKETING $2,000", etc. appeared as floating orphan-
-- style lines at the bottom of the agency P&L. Change the section resolution to
-- match get_pnl_history_for_entity: section = COALESCE(r.root_name, 'Uncategorized').
-- Direct-to-parent bookings now render under the parent's own section (with the
-- leaf labeled by the parent's own name). Cross-entity leaks (Personal / PaperNewt
-- COAs referenced from agency JEs) render under their own root name as a distinct
-- section — visible + labeled, not silently hidden.
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
      -- Section = root_name of the parent chain. If a leaf IS its own root
      -- (legitimate root parent or true orphan), section = own name — which
      -- naturally lands direct-to-parent bookings inside their parent section
      -- and surfaces cross-entity orphans under a labeled section instead of
      -- an "Expense" fallback catchall.
      COALESCE(r.root_name, 'Uncategorized') AS section,
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

