-- Fix P&L drill panel returning zero transactions.
--
-- Bug: pnl_drill_transactions filtered on cr.root_name = p_section, but the
-- P&L display (get_pnl_history_own_only) derives section as
--   COALESCE(NULLIF(root_name, account_name), INITCAP(account_type))
-- so for personal accounts (no parent → self is root), the display shows
-- section='Income'/'Expense' while the drill filter compared root_name
-- against literal 'Income'/'Expense' → 0 rows.
--
-- Also: drill had no entity filter, so it was cross-entity while the P&L
-- display is entity-scoped. Added p_entity_id required arg + pyp_side NULL
-- section handling (COALESCE) to mirror pre_cutover branch of P&L RPC.
--
-- Arity change → drop old signature first.

DROP FUNCTION IF EXISTS public.pnl_drill_transactions(text, text, text, date, date);

CREATE OR REPLACE FUNCTION public.pnl_drill_transactions(
  p_entity_id     uuid,
  p_account_name  text,
  p_section       text,
  p_account_type  text,
  p_from_date     date,
  p_to_date       date
)
RETURNS TABLE (
  source                 text,
  je_id                  uuid,
  line_id                uuid,
  pyp_id                 uuid,
  entry_date             date,
  amount                 numeric,
  description            text,
  memo                   text,
  reference_number       text,
  je_source              text,
  classification_status  text,
  account_id             uuid,
  account_code           text,
  account_name           text,
  document_id            uuid,
  created_at             timestamptz
)
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
  journal_side AS (
    SELECT
      'journal'::text                                       AS source,
      je.id                                                 AS je_id,
      jl.id                                                 AS line_id,
      NULL::uuid                                            AS pyp_id,
      je.entry_date                                         AS entry_date,
      CASE
        WHEN coa.account_type = 'income'  AND je.source LIKE 'historical_import%'
             THEN COALESCE(jl.debit,0)  - COALESCE(jl.credit,0)
        WHEN coa.account_type = 'income'
             THEN COALESCE(jl.credit,0) - COALESCE(jl.debit,0)
        WHEN coa.account_type = 'expense'
             THEN COALESCE(jl.debit,0)  - COALESCE(jl.credit,0)
        ELSE 0
      END                                                   AS amount,
      COALESCE(jl.description, je.description)              AS description,
      je.memo                                               AS memo,
      je.reference_number                                   AS reference_number,
      je.source                                             AS je_source,
      je.classification_status                              AS classification_status,
      coa.id                                                AS account_id,
      coa.account_code                                      AS account_code,
      coa.account_name                                      AS account_name,
      je.document_id                                        AS document_id,
      je.created_at                                         AS created_at
    FROM public.journal_lines  jl
    JOIN public.journal_entries    je  ON je.id  = jl.journal_entry_id
    JOIN public.chart_of_accounts  coa ON coa.id = jl.account_id
    LEFT JOIN coa_root             cr  ON cr.leaf_id = coa.id
    WHERE je.agency_id            = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND je.business_entity_id   = p_entity_id
      AND coa.account_type        = p_account_type
      AND coa.account_name        = p_account_name
      -- Match P&L display's section derivation: flat/root accounts collapse
      -- to INITCAP(account_type); parented accounts show their root name.
      AND COALESCE(
            NULLIF(cr.root_name, coa.account_name),
            INITCAP(coa.account_type::text)
          )                       = p_section
      AND je.entry_date          >= p_from_date
      AND je.entry_date          <= p_to_date
  ),
  pyp_side AS (
    SELECT
      'prior_year_pl'::text                                 AS source,
      NULL::uuid                                            AS je_id,
      NULL::uuid                                            AS line_id,
      py.id                                                 AS pyp_id,
      COALESCE(py.period_start,
        make_date(py.period_year, py.period_month, 1))      AS entry_date,
      py.amount                                             AS amount,
      NULL::text                                            AS description,
      NULL::text                                            AS memo,
      NULL::text                                            AS reference_number,
      'prior_year_pl_import'::text                          AS je_source,
      NULL::text                                            AS classification_status,
      NULL::uuid                                            AS account_id,
      NULL::text                                            AS account_code,
      py.account_name                                       AS account_name,
      py.source_document_id                                 AS document_id,
      py.imported_at                                        AS created_at
    FROM public.prior_year_pl py
    WHERE py.agency_id            = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND py.business_entity_id   = p_entity_id
      AND lower(py.section_type)  = lower(p_account_type)
      AND py.account_name         = p_account_name
      -- Mirror pre_cutover branch of get_pnl_history_own_only which uses
      -- COALESCE(py.section, 'Uncategorized') as the display section.
      AND COALESCE(py.section, 'Uncategorized') = p_section
      AND make_date(py.period_year, py.period_month, 1) >= date_trunc('month', p_from_date)::date
      AND make_date(py.period_year, py.period_month, 1) <= date_trunc('month', p_to_date)::date
  )
  SELECT * FROM journal_side
  UNION ALL
  SELECT * FROM pyp_side
  ORDER BY entry_date DESC, created_at DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.pnl_drill_transactions(uuid, text, text, text, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pnl_drill_transactions(uuid, text, text, text, date, date) TO anon;
