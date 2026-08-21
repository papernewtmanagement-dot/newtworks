-- Phase 2: SQL roll-up layer for hierarchical Financials.
-- Additive only. Existing v_income_statement / get_pnl_history / pnl_drill_transactions
-- untouched — Phase 3 UI decides caller swap timing.
--
-- Ships:
--   1. get_entity_descendants(uuid) -> uuid[]        (self + all descendants)
--   2. v_entity_hierarchy                            (tree with depth + path + is_leaf)
--   3. get_entity_direct_children(uuid) -> table     (drill-down UI feed)
--   4. get_pnl_history_for_entity(uuid) -> json      (P&L RPC, roll-up over descendants)

-- 1. Descendants helper
CREATE OR REPLACE FUNCTION public.get_entity_descendants(p_entity_id uuid)
RETURNS uuid[]
LANGUAGE sql
STABLE
AS $$
  WITH RECURSIVE descendants AS (
    SELECT id FROM public.business_entities WHERE id = p_entity_id
    UNION ALL
    SELECT e.id
    FROM public.business_entities e
    JOIN descendants d ON e.parent_entity_id = d.id
  )
  SELECT COALESCE(ARRAY_AGG(id), ARRAY[]::uuid[]) FROM descendants;
$$;

-- 2. Hierarchy view
CREATE OR REPLACE VIEW public.v_entity_hierarchy AS
WITH RECURSIVE tree AS (
  SELECT
    id, agency_id, name, slug, entity_type, parent_entity_id, status, ein,
    id AS root_id,
    0 AS depth,
    name::text AS path
  FROM public.business_entities
  WHERE parent_entity_id IS NULL
  UNION ALL
  SELECT
    e.id, e.agency_id, e.name, e.slug, e.entity_type, e.parent_entity_id, e.status, e.ein,
    t.root_id,
    t.depth + 1,
    t.path || ' > ' || e.name
  FROM public.business_entities e
  JOIN tree t ON e.parent_entity_id = t.id
),
child_counts AS (
  SELECT parent_entity_id AS id, COUNT(*)::int AS direct_child_count
  FROM public.business_entities
  WHERE parent_entity_id IS NOT NULL
  GROUP BY parent_entity_id
)
SELECT
  t.id, t.agency_id, t.name, t.slug, t.entity_type, t.parent_entity_id, t.status, t.ein,
  t.root_id, t.depth, t.path,
  COALESCE(cc.direct_child_count, 0) AS direct_child_count,
  (COALESCE(cc.direct_child_count, 0) = 0) AS is_leaf
FROM tree t
LEFT JOIN child_counts cc ON cc.id = t.id;

-- 3. Direct children helper
CREATE OR REPLACE FUNCTION public.get_entity_direct_children(p_entity_id uuid)
RETURNS TABLE(
  id uuid,
  name text,
  slug text,
  entity_type text,
  status text,
  is_leaf boolean,
  direct_child_count int
)
LANGUAGE sql
STABLE
AS $$
  SELECT v.id, v.name, v.slug, v.entity_type, v.status, v.is_leaf, v.direct_child_count
  FROM public.v_entity_hierarchy v
  WHERE v.parent_entity_id = p_entity_id
  ORDER BY v.name;
$$;

-- 4. P&L rollup RPC
-- Same JSON shape as get_pnl_history() but scoped to entity + descendants via business_entity_id.
-- Post-cutover uses journal_entries.business_entity_id.
-- Pre-cutover uses prior_year_pl.business_entity_id.
CREATE OR REPLACE FUNCTION public.get_pnl_history_for_entity(p_entity_id uuid)
RETURNS json
LANGUAGE sql
STABLE
AS $$
  WITH RECURSIVE descendants AS (
    SELECT id FROM public.business_entities WHERE id = p_entity_id
    UNION ALL
    SELECT e.id FROM public.business_entities e
    JOIN descendants d ON e.parent_entity_id = d.id
  ),
  ancestry AS (
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
      AND je.business_entity_id = ANY (SELECT id FROM descendants)
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
      AND py.business_entity_id = ANY (SELECT id FROM descendants)
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
$$;

-- Grants matching sibling functions
GRANT EXECUTE ON FUNCTION public.get_entity_descendants(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_entity_direct_children(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_pnl_history_for_entity(uuid) TO anon, authenticated, service_role;
GRANT SELECT ON public.v_entity_hierarchy TO anon, authenticated, service_role;
