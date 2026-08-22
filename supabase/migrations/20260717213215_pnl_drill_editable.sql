-- pnl_drill_editable
-- RLS admin write policies + pnl_drill_transactions RPC. See mirror at
-- supabase/migrations/*_pnl_drill_editable.sql for full comments.

-- ============================================================================
-- 1. RLS policies — admin (owner/manager) write access, agency-scoped
-- ============================================================================

DROP POLICY IF EXISTS journal_entries_admin_update ON public.journal_entries;
CREATE POLICY journal_entries_admin_update
  ON public.journal_entries
  FOR UPDATE
  TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  );

DROP POLICY IF EXISTS journal_entries_admin_delete ON public.journal_entries;
CREATE POLICY journal_entries_admin_delete
  ON public.journal_entries
  FOR DELETE
  TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
    )
  );

DROP POLICY IF EXISTS journal_lines_admin_update ON public.journal_lines;
CREATE POLICY journal_lines_admin_update
  ON public.journal_lines
  FOR UPDATE
  TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  );

DROP POLICY IF EXISTS journal_lines_admin_delete ON public.journal_lines;
CREATE POLICY journal_lines_admin_delete
  ON public.journal_lines
  FOR DELETE
  TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
    )
  );

DROP POLICY IF EXISTS prior_year_pl_admin_update ON public.prior_year_pl;
CREATE POLICY prior_year_pl_admin_update
  ON public.prior_year_pl
  FOR UPDATE
  TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  );

DROP POLICY IF EXISTS prior_year_pl_admin_delete ON public.prior_year_pl;
CREATE POLICY prior_year_pl_admin_delete
  ON public.prior_year_pl
  FOR DELETE
  TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('owner','manager')
    )
  );

-- ============================================================================
-- 2. pnl_drill_transactions RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pnl_drill_transactions(
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
AS $$
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
    WHERE je.agency_id      = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND coa.account_type  = p_account_type
      AND coa.account_name  = p_account_name
      AND COALESCE(cr.root_name, 'Uncategorized') = p_section
      AND je.entry_date    >= p_from_date
      AND je.entry_date    <= p_to_date
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
    WHERE py.agency_id      = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND lower(py.section_type) = lower(p_account_type)
      AND py.account_name   = p_account_name
      AND py.section        = p_section
      AND make_date(py.period_year, py.period_month, 1) >= date_trunc('month', p_from_date)::date
      AND make_date(py.period_year, py.period_month, 1) <= date_trunc('month', p_to_date)::date
  )
  SELECT * FROM journal_side
  UNION ALL
  SELECT * FROM pyp_side
  ORDER BY entry_date DESC, created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.pnl_drill_transactions(text, text, text, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pnl_drill_transactions(text, text, text, date, date) TO anon;

