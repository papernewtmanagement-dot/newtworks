-- (a) Normalize prior_year_pl.section values on PSS to Peter's 5-section scheme
-- so historical P&L rows render under the same section headers as current.
UPDATE public.prior_year_pl
SET section = CASE section
  WHEN '0001 ADMINISTRATION'      THEN 'Admin'
  WHEN '0003 TEAM'                THEN 'Team'
  WHEN '0003a Mortgage Marketing' THEN 'Marketing'
  WHEN '0004 MARKETING'           THEN 'Marketing'
  WHEN '0005 DISCRETIONARY'       THEN 'Admin'
  WHEN '0006 PERSONAL'            THEN 'Personal'
  ELSE section
END
WHERE section IN (
  '0001 ADMINISTRATION','0003 TEAM','0003a Mortgage Marketing',
  '0004 MARKETING','0005 DISCRETIONARY','0006 PERSONAL'
);

-- (b) get_pnl_history_own_only: add Growth tag routing on expense lines
CREATE OR REPLACE FUNCTION public.get_pnl_history_own_only(p_entity_id uuid)
RETURNS json
LANGUAGE sql
STABLE
AS $function$
  WITH post_cutover AS (
    SELECT EXTRACT(year FROM je.entry_date)::int AS year,
           EXTRACT(month FROM je.entry_date)::int AS month,
           coa.account_name, coa.account_type::text AS account_type,
           CASE
             WHEN coa.account_type = 'expense'
              AND EXISTS (
                SELECT 1 FROM public.transaction_tags tt
                 WHERE tt.journal_line_id = jl.id
                   AND tt.tag_key   = 'budget_category'
                   AND tt.tag_value = 'growth'
              )
             THEN 'Growth'
             ELSE COALESCE(
               coa.section_label_override,
               INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' '))
             )
           END AS section,
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
    GROUP BY je.entry_date, je.source, jl.id, coa.id, coa.account_name,
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

-- (c) get_pnl_history_for_entity: same Growth tag routing (with descendants walk)
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
           CASE
             WHEN coa.account_type = 'expense'
              AND EXISTS (
                SELECT 1 FROM public.transaction_tags tt
                 WHERE tt.journal_line_id = jl.id
                   AND tt.tag_key   = 'budget_category'
                   AND tt.tag_value = 'growth'
              )
             THEN 'Growth'
             ELSE COALESCE(
               coa.section_label_override,
               INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' '))
             )
           END AS section,
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
    GROUP BY je.entry_date, je.source, jl.id, coa.id, coa.account_name,
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
