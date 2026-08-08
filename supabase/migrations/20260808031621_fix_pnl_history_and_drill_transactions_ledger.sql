-- 2026-08-08: journal_entries + journal_lines were dropped and merged into public.ledger
-- by the finrebuild (20260808001345..20260808022601). These three P&L reporting functions
-- were still written against the old two-table shape and would have errored the next time
-- Financials.jsx opened P&L history or drilled into a transaction. Re-pointed at ledger.

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
    SELECT EXTRACT(year FROM l.entry_date)::int AS year,
           EXTRACT(month FROM l.entry_date)::int AS month,
           coa.account_name, coa.account_type::text AS account_type,
           CASE
             WHEN coa.account_type = 'expense'
              AND EXISTS (
                SELECT 1 FROM public.transaction_tags tt
                 WHERE tt.journal_line_id = l.id
                   AND tt.tag_key   = 'budget_category'
                   AND tt.tag_value = 'growth'
              )
             THEN 'Growth'
             WHEN coa.business_entity_id = 'b2222222-2222-2222-2222-222222222222'::uuid
             THEN COALESCE(
               coa.section_label_override,
               INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' '))
             )
             ELSE COALESCE(coa.section_label_override, INITCAP(coa.account_type::text))
           END AS section,
      CASE
        WHEN coa.account_type = 'income'  AND l.source LIKE 'historical_import%' THEN SUM(l.debit) - SUM(l.credit)
        WHEN coa.account_type = 'income'  THEN SUM(l.credit) - SUM(l.debit)
        WHEN coa.account_type = 'expense' THEN SUM(l.debit) - SUM(l.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.ledger l
    JOIN public.chart_of_accounts coa ON coa.id = l.account_id
    WHERE coa.account_type IN ('income','expense')
      AND coa.business_entity_id = ANY (SELECT id FROM descendants)
      AND l.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    GROUP BY l.entry_date, l.source, l.id, coa.id, coa.account_name,
             coa.account_type, coa.account_subtype, coa.section_label_override, coa.business_entity_id
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type,
           CASE
             WHEN py.business_entity_id = 'b2222222-2222-2222-2222-222222222222'::uuid
             THEN COALESCE(py.section, 'Uncategorized')
             ELSE INITCAP(py.section_type)
           END AS section,
           py.amount
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

CREATE OR REPLACE FUNCTION public.get_pnl_history_own_only(p_entity_id uuid)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
  WITH post_cutover AS (
    SELECT EXTRACT(year FROM l.entry_date)::int AS year,
           EXTRACT(month FROM l.entry_date)::int AS month,
           coa.account_name, coa.account_type::text AS account_type,
           CASE
             WHEN coa.account_type = 'expense'
              AND EXISTS (
                SELECT 1 FROM public.transaction_tags tt
                 WHERE tt.journal_line_id = l.id
                   AND tt.tag_key   = 'budget_category'
                   AND tt.tag_value = 'growth'
              )
             THEN 'Growth'
             WHEN coa.business_entity_id = 'b2222222-2222-2222-2222-222222222222'::uuid
             THEN COALESCE(
               coa.section_label_override,
               INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' '))
             )
             ELSE COALESCE(coa.section_label_override, INITCAP(coa.account_type::text))
           END AS section,
      CASE
        WHEN coa.account_type = 'income'  AND l.source LIKE 'historical_import%' THEN SUM(l.debit) - SUM(l.credit)
        WHEN coa.account_type = 'income'  THEN SUM(l.credit) - SUM(l.debit)
        WHEN coa.account_type = 'expense' THEN SUM(l.debit) - SUM(l.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.ledger l
    JOIN public.chart_of_accounts coa ON coa.id = l.account_id
    WHERE coa.account_type IN ('income','expense')
      AND coa.business_entity_id = p_entity_id
      AND l.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    GROUP BY l.entry_date, l.source, l.id, coa.id, coa.account_name,
             coa.account_type, coa.account_subtype, coa.section_label_override, coa.business_entity_id
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type,
           CASE
             WHEN py.business_entity_id = 'b2222222-2222-2222-2222-222222222222'::uuid
             THEN COALESCE(py.section, 'Uncategorized')
             ELSE INITCAP(py.section_type)
           END AS section,
           py.amount
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

CREATE OR REPLACE FUNCTION public.pnl_drill_transactions(p_entity_id uuid, p_account_name text, p_section text, p_account_type text, p_from_date date, p_to_date date)
 RETURNS TABLE(source text, je_id uuid, line_id uuid, pyp_id uuid, entry_date date, amount numeric, description text, memo text, reference_number text, je_source text, classification_status text, account_id uuid, account_code text, account_name text, document_id uuid, created_at timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
  WITH RECURSIVE descendants AS (
    SELECT id FROM public.business_entities WHERE id = p_entity_id
    UNION ALL
    SELECT e.id FROM public.business_entities e JOIN descendants d ON e.parent_entity_id = d.id
  ),
  journal_side AS (
    SELECT
      'journal'::text AS source,
      l.id AS je_id,
      l.id AS line_id,
      NULL::uuid AS pyp_id,
      l.entry_date,
      CASE
        WHEN coa.account_type = 'income'  AND l.source LIKE 'historical_import%' THEN COALESCE(l.debit,0) - COALESCE(l.credit,0)
        WHEN coa.account_type = 'income'  THEN COALESCE(l.credit,0) - COALESCE(l.debit,0)
        WHEN coa.account_type = 'expense' THEN COALESCE(l.debit,0) - COALESCE(l.credit,0)
        ELSE 0
      END AS amount,
      l.description AS description,
      l.memo,
      l.reference_number,
      l.source AS je_source,
      l.classification_status,
      coa.id AS account_id,
      coa.account_code,
      coa.account_name,
      l.document_id,
      l.created_at,
      CASE
        WHEN coa.account_type = 'expense'
         AND EXISTS (
           SELECT 1 FROM public.transaction_tags tt
            WHERE tt.journal_line_id = l.id
              AND tt.tag_key   = 'budget_category'
              AND tt.tag_value = 'growth'
         )
        THEN 'Growth'
        WHEN coa.business_entity_id = 'b2222222-2222-2222-2222-222222222222'::uuid
        THEN COALESCE(
          coa.section_label_override,
          INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' '))
        )
        ELSE COALESCE(coa.section_label_override, INITCAP(coa.account_type::text))
      END AS derived_section
    FROM public.ledger l
    JOIN public.chart_of_accounts coa ON coa.id = l.account_id
    WHERE l.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND coa.business_entity_id = ANY (SELECT id FROM descendants)
      AND coa.account_type = p_account_type
      AND coa.account_name = p_account_name
      AND l.entry_date BETWEEN p_from_date AND p_to_date
  ),
  pyp_side AS (
    SELECT
      'prior_year_pl'::text AS source,
      NULL::uuid AS je_id,
      NULL::uuid AS line_id,
      py.id AS pyp_id,
      COALESCE(py.period_start, make_date(py.period_year, py.period_month, 1)) AS entry_date,
      py.amount,
      NULL::text AS description,
      NULL::text AS memo,
      NULL::text AS reference_number,
      'prior_year_pl_import'::text AS je_source,
      NULL::text AS classification_status,
      NULL::uuid AS account_id,
      NULL::text AS account_code,
      py.account_name,
      py.source_document_id AS document_id,
      py.imported_at AS created_at,
      CASE
        WHEN py.business_entity_id = 'b2222222-2222-2222-2222-222222222222'::uuid
        THEN COALESCE(py.section, 'Uncategorized')
        ELSE INITCAP(py.section_type)
      END AS derived_section
    FROM public.prior_year_pl py
    WHERE py.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND py.business_entity_id = ANY (SELECT id FROM descendants)
      AND LOWER(py.section_type) = LOWER(p_account_type)
      AND py.account_name = p_account_name
      AND make_date(py.period_year, py.period_month, 1)
          BETWEEN date_trunc('month', p_from_date)::date
              AND date_trunc('month', p_to_date)::date
  ),
  combined AS (
    SELECT * FROM journal_side
    UNION ALL
    SELECT * FROM pyp_side
  )
  SELECT source, je_id, line_id, pyp_id, entry_date, amount, description, memo,
         reference_number, je_source, classification_status, account_id,
         account_code, account_name, document_id, created_at
  FROM combined
  WHERE derived_section = p_section
  ORDER BY entry_date DESC, created_at DESC;
$function$;
