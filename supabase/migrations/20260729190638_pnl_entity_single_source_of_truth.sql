-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-29 19:06:38 UTC (ledger name: pnl_entity_single_source_of_truth) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260729190638.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Architectural fix: chart_of_accounts.business_entity_id is the ONLY column that
-- decides which entity's P&L an income/expense line appears on. Prior code filtered
-- by journal_entries.business_entity_id, which could diverge from the account's own
-- entity assignment (e.g. bank_gl_writer stamps the JE with the bank's entity, but
-- the income account itself lives on a different entity). New rule: reads join
-- through journal_lines → chart_of_accounts and filter on coa.business_entity_id.

CREATE OR REPLACE FUNCTION public.get_pnl_history_for_entity(p_entity_id uuid)
 RETURNS json LANGUAGE sql STABLE
AS $function$
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
    SELECT leaf_id, account_name AS root_name FROM ancestry WHERE parent_account_id IS NULL
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
        WHEN coa.account_type = 'income' THEN SUM(jl.credit) - SUM(jl.debit)
        WHEN coa.account_type = 'expense' THEN SUM(jl.debit) - SUM(jl.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.journal_lines jl
    JOIN public.journal_entries je ON je.id = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    LEFT JOIN coa_root r ON r.leaf_id = coa.id
    WHERE coa.account_type IN ('income','expense')
      AND coa.business_entity_id = ANY (SELECT id FROM descendants)   -- CHANGED
    GROUP BY je.entry_date, je.source, coa.id, coa.account_name, coa.account_type, r.root_name
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type, COALESCE(py.section, 'Uncategorized') AS section, py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense')
      AND py.business_entity_id = ANY (SELECT id FROM descendants)
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

CREATE OR REPLACE FUNCTION public.get_pnl_history_own_only(p_entity_id uuid)
 RETURNS json LANGUAGE sql STABLE
AS $function$
  WITH RECURSIVE ancestry AS (
    SELECT id AS leaf_id, id AS cur_id, account_name, parent_account_id FROM public.chart_of_accounts
    UNION ALL
    SELECT a.leaf_id, p.id, p.account_name, p.parent_account_id
    FROM public.chart_of_accounts p JOIN ancestry a ON a.parent_account_id = p.id
  ),
  coa_root AS (
    SELECT leaf_id, account_name AS root_name FROM ancestry WHERE parent_account_id IS NULL
  ),
  post_cutover AS (
    SELECT
      EXTRACT(year FROM je.entry_date)::int AS year,
      EXTRACT(month FROM je.entry_date)::int AS month,
      coa.account_name, coa.account_type::text AS account_type,
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
    WHERE coa.account_type IN ('income','expense')
      AND coa.business_entity_id = p_entity_id                                          -- CHANGED
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

CREATE OR REPLACE FUNCTION public.pnl_drill_transactions(p_entity_id uuid, p_account_name text, p_section text, p_account_type text, p_from_date date, p_to_date date)
 RETURNS TABLE(source text, je_id uuid, line_id uuid, pyp_id uuid, entry_date date, amount numeric, description text, memo text, reference_number text, je_source text, classification_status text, account_id uuid, account_code text, account_name text, document_id uuid, created_at timestamp with time zone)
 LANGUAGE sql STABLE
AS $function$
  WITH RECURSIVE ancestry AS (
    SELECT id AS leaf_id, id AS cur_id, account_name, parent_account_id FROM public.chart_of_accounts
    UNION ALL
    SELECT a.leaf_id, p.id, p.account_name, p.parent_account_id
    FROM public.chart_of_accounts p JOIN ancestry a ON a.parent_account_id = p.id
  ),
  coa_root AS (
    SELECT leaf_id, account_name AS root_name FROM ancestry WHERE parent_account_id IS NULL
  ),
  journal_side AS (
    SELECT 'journal'::text AS source, je.id AS je_id, jl.id AS line_id, NULL::uuid AS pyp_id, je.entry_date,
      CASE
        WHEN coa.account_type = 'income' AND je.source LIKE 'historical_import%' THEN COALESCE(jl.debit,0) - COALESCE(jl.credit,0)
        WHEN coa.account_type = 'income' THEN COALESCE(jl.credit,0) - COALESCE(jl.debit,0)
        WHEN coa.account_type = 'expense' THEN COALESCE(jl.debit,0) - COALESCE(jl.credit,0)
        ELSE 0
      END AS amount,
      COALESCE(jl.description, je.description) AS description, je.memo, je.reference_number,
      je.source AS je_source, je.classification_status, coa.id AS account_id, coa.account_code, coa.account_name,
      je.document_id, je.created_at
    FROM public.journal_lines jl
    JOIN public.journal_entries je ON je.id = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    LEFT JOIN coa_root cr ON cr.leaf_id = coa.id
    WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND coa.business_entity_id = p_entity_id                                          -- CHANGED
      AND coa.account_type = p_account_type
      AND coa.account_name = p_account_name
      AND COALESCE(NULLIF(cr.root_name, coa.account_name), INITCAP(coa.account_type::text)) = p_section
      AND je.entry_date >= p_from_date AND je.entry_date <= p_to_date
  ),
  pyp_side AS (
    SELECT 'prior_year_pl'::text, NULL::uuid, NULL::uuid, py.id,
      COALESCE(py.period_start, make_date(py.period_year, py.period_month, 1)),
      py.amount, NULL::text, NULL::text, NULL::text, 'prior_year_pl_import'::text, NULL::text,
      NULL::uuid, NULL::text, py.account_name, py.source_document_id, py.imported_at
    FROM public.prior_year_pl py
    WHERE py.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND py.business_entity_id = p_entity_id
      AND lower(py.section_type) = lower(p_account_type)
      AND py.account_name = p_account_name
      AND COALESCE(py.section, 'Uncategorized') = p_section
      AND make_date(py.period_year, py.period_month, 1) >= date_trunc('month', p_from_date)::date
      AND make_date(py.period_year, py.period_month, 1) <= date_trunc('month', p_to_date)::date
  )
  SELECT * FROM journal_side UNION ALL SELECT * FROM pyp_side
  ORDER BY entry_date DESC, created_at DESC;
$function$;

-- Mark je.business_entity_id as deprecated so future developers know not to depend on it
COMMENT ON COLUMN public.journal_entries.business_entity_id IS
  'DEPRECATED as of 2026-07-29. Entity attribution for P&L display is derived from chart_of_accounts.business_entity_id on the journal line''s account. This column is retained for backwards compatibility with existing writers but is not read by any P&L, drill, or income statement query. Do not filter or aggregate by this column.';

GRANT EXECUTE ON FUNCTION public.get_pnl_history_for_entity(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pnl_history_own_only(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pnl_drill_transactions(uuid, text, text, text, date, date) TO authenticated;
