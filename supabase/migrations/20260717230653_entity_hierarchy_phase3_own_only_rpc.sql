-- Phase 3 (Financials hierarchy): own-only P&L RPC
--
-- Companion to get_pnl_history_for_entity(uuid), which does full-consolidation
-- (self + every descendant merged line-by-line). This one-line-consolidation
-- helper returns ONLY journal entries stamped exactly to p_entity_id, no
-- descendant recursion. Frontend uses this at every level to render "own P&L
-- rows" and then calls get_pnl_history_for_entity(child) for each direct child
-- to append per-child net summary lines.
--
-- Same output shape as get_pnl_history() and get_pnl_history_for_entity():
--   json array of { year, month, account_name, account_type, section, amount }
--
-- Reconciliation guarantee:
--   sum(get_pnl_history_own_only(root)) +
--   sum(get_pnl_history_for_entity(each direct child of root))
--   == sum(get_pnl_history_for_entity(root))
--
-- Because own_only + non-overlapping child subtrees = full descendants set.

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
    FROM ancestry
    WHERE parent_account_id IS NULL
  ),
  post_cutover AS (
    SELECT
      EXTRACT(year FROM je.entry_date)::int AS year,
      EXTRACT(month FROM je.entry_date)::int AS month,
      coa.account_name,
      coa.account_type::text AS account_type,
      COALESCE(r.root_name, 'Uncategorized') AS section,
      CASE
        WHEN coa.account_type = 'income' AND je.source LIKE 'historical_import%'
          THEN SUM(jl.debit) - SUM(jl.credit)
        WHEN coa.account_type = 'income'
          THEN SUM(jl.credit) - SUM(jl.debit)
        WHEN coa.account_type = 'expense'
          THEN SUM(jl.debit) - SUM(jl.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.journal_lines jl
    JOIN public.journal_entries je ON je.id = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    LEFT JOIN coa_root r ON r.leaf_id = coa.id
    WHERE coa.account_type IN ('income','expense')
      AND je.business_entity_id = p_entity_id
    GROUP BY je.entry_date, je.source, coa.id, coa.account_name, coa.account_type, r.root_name
  ),
  pre_cutover AS (
    SELECT
      py.period_year AS year,
      py.period_month AS month,
      py.account_name,
      LOWER(py.section_type) AS account_type,
      COALESCE(py.section, 'Uncategorized') AS section,
      py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense')
      AND py.business_entity_id = p_entity_id
  ),
  combined AS (
    SELECT year, month, account_name, account_type, section, amount FROM post_cutover
    UNION ALL
    SELECT year, month, account_name, account_type, section, amount FROM pre_cutover
  )
  SELECT COALESCE(
    json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name),
    '[]'::json
  )
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM combined
    GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;

GRANT EXECUTE ON FUNCTION public.get_pnl_history_own_only(uuid) TO authenticated, anon, service_role;
