-- pnl_drill_transactions: scope the drill panel to the SAME entity as the cell
-- it was opened from.
--
-- Bug: the drill walked the whole entity tree (self + every descendant) while the
-- P&L rows it opens from come from get_pnl_history_own_only, which is exact-entity
-- by design (children appear separately as one rolled-up net line in the
-- Subsidiaries block). So on any parent entity, clicking a cell opened a list that
-- included child-entity transactions the cell itself excluded, and the panel header
-- total did not match the cell.
--
-- Live example before this fix: Personal > Tithe & Charitable, Jan-Jul 2026 --
-- cell showed Personal's own giving, drill added PaperNewt LLC's recurring
-- $566.38/month foster-care gift on top, every month.
--
-- The descendant walk was inherited from the Phase 2 roll-up layer
-- (20260717224144) and carried through every later revision. It was never
-- deliberate for this function: nothing in the panel labels which entity a row
-- belongs to, so the extra rows were indistinguishable from the entity's own.
--
-- Fix: exact-entity on both halves (live ledger and prior-year imports).
-- CREATE OR REPLACE, not DROP + CREATE, so existing EXECUTE grants survive.
-- Signature, return columns, amount signs and section derivation all unchanged.

CREATE OR REPLACE FUNCTION public.pnl_drill_transactions(
  p_entity_id uuid, p_account_name text, p_section text,
  p_account_type text, p_from_date date, p_to_date date)
 RETURNS TABLE(source text, je_id uuid, line_id uuid, pyp_id uuid, entry_date date,
   amount numeric, description text, memo text, reference_number text, je_source text,
   classification_status text, account_id uuid, account_code text, account_name text,
   document_id uuid, created_at timestamp with time zone, confirmation text,
   cash_register_id uuid, business_entity_id uuid)
 LANGUAGE sql
 STABLE
AS $function$
  WITH journal_side AS (
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
      END AS derived_section,
      vlc.confirmation AS confirmation,
      l.cash_register_id AS cash_register_id,
      coa.business_entity_id AS business_entity_id
    FROM public.ledger l
    JOIN public.chart_of_accounts coa ON coa.id = l.account_id
    LEFT JOIN public.v_ledger_confirmation vlc ON vlc.ledger_id = l.id
    WHERE l.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND coa.business_entity_id = p_entity_id
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
      END AS derived_section,
      NULL::text AS confirmation,
      NULL::uuid AS cash_register_id,
      py.business_entity_id AS business_entity_id
    FROM public.prior_year_pl py
    WHERE py.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND py.business_entity_id = p_entity_id
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
         account_code, account_name, document_id, created_at, confirmation, cash_register_id,
         business_entity_id
  FROM combined
  WHERE derived_section = p_section
  ORDER BY entry_date DESC, created_at DESC;
$function$;
