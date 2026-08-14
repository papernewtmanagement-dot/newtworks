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
      END AS amount,
      bool_or(vlc.confirmation = 'awaiting_statement') AS awaiting_statement,
      bool_or(vlc.confirmation = 'not_on_statement') AS not_on_statement
    FROM public.ledger l
    JOIN public.chart_of_accounts coa ON coa.id = l.account_id
    LEFT JOIN public.v_ledger_confirmation vlc ON vlc.ledger_id = l.id
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
           py.amount,
           FALSE AS awaiting_statement,
           FALSE AS not_on_statement
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense')
      AND py.business_entity_id = ANY (SELECT id FROM descendants)
  ),
  combined AS (SELECT * FROM post_cutover UNION ALL SELECT * FROM pre_cutover)
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount,
           COALESCE(bool_or(awaiting_statement), false) AS awaiting_statement,
           COALESCE(bool_or(not_on_statement), false) AS not_on_statement
    FROM combined GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;
