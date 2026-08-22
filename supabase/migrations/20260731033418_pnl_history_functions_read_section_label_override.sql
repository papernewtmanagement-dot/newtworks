-- Fix section headers on the P&L for real this time. Two P&L functions get
-- their section computation updated to prefer chart_of_accounts.section_label_override
-- when set. Plus one tiny data fix: 'Expenses' → 'Expense' on non-agency expense
-- accounts, so the frontend's redundant-section suppression actually catches them.

--------------------------------------------------------------------------------
-- Part 1: Data typo fix
--------------------------------------------------------------------------------

UPDATE public.chart_of_accounts
SET section_label_override = 'Expense'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id <> 'b2222222-2222-2222-2222-222222222222'
  AND account_type = 'expense'
  AND section_label_override = 'Expenses';

--------------------------------------------------------------------------------
-- Part 2: get_pnl_history_own_only — reads section_label_override
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_pnl_history_own_only(p_entity_id uuid)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
  WITH post_cutover AS (
    SELECT EXTRACT(year FROM je.entry_date)::int AS year,
           EXTRACT(month FROM je.entry_date)::int AS month,
           coa.account_name, coa.account_type::text AS account_type,
           COALESCE(
             coa.section_label_override,
             INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' '))
           ) AS section,
      CASE
        WHEN coa.account_type = 'income'  AND je.source LIKE 'historical_import%' THEN SUM(jl.debit) - SUM(jl.credit)
        WHEN coa.account_type = 'income'  THEN SUM(jl.credit) - SUM(jl.debit)
        WHEN coa.account_type = 'expense' THEN SUM(jl.debit) - SUM(jl.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.journal_lines jl
    JOIN public.journal_entries je   ON je.id  = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE coa.account_type IN ('income','expense')
      AND coa.business_entity_id = p_entity_id
    GROUP BY je.entry_date, je.source, coa.id, coa.account_name,
             coa.account_type, coa.account_subtype, coa.section_label_override
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type, COALESCE(py.section, 'Uncategorized') AS section, py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense') AND py.business_entity_id = p_entity_id
  ),
  combined AS (SELECT * FROM post_cutover UNION ALL SELECT * FROM pre_cutover)
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM combined GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;

--------------------------------------------------------------------------------
-- Part 3: get_pnl_history_for_entity — same override, plus subsidiary rollup
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_pnl_history_for_entity(p_entity_id uuid)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
  WITH RECURSIVE descendants AS (
    SELECT id FROM public.business_entities WHERE id = p_entity_id
    UNION ALL
    SELECT e.id FROM public.business_entities e JOIN descendants d ON e.parent_entity_id = d.id
  ),
  post_cutover AS (
    SELECT EXTRACT(year FROM je.entry_date)::int AS year,
           EXTRACT(month FROM je.entry_date)::int AS month,
           coa.account_name, coa.account_type::text AS account_type,
           COALESCE(
             coa.section_label_override,
             INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' '))
           ) AS section,
      CASE
        WHEN coa.account_type = 'income'  AND je.source LIKE 'historical_import%' THEN SUM(jl.debit) - SUM(jl.credit)
        WHEN coa.account_type = 'income'  THEN SUM(jl.credit) - SUM(jl.debit)
        WHEN coa.account_type = 'expense' THEN SUM(jl.debit) - SUM(jl.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.journal_lines jl
    JOIN public.journal_entries je   ON je.id  = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE coa.account_type IN ('income','expense')
      AND coa.business_entity_id = ANY (SELECT id FROM descendants)
    GROUP BY je.entry_date, je.source, coa.id, coa.account_name,
             coa.account_type, coa.account_subtype, coa.section_label_override
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type, COALESCE(py.section, 'Uncategorized') AS section, py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense')
      AND py.business_entity_id = ANY (SELECT id FROM descendants)
  ),
  combined AS (SELECT * FROM post_cutover UNION ALL SELECT * FROM pre_cutover)
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM combined GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;
