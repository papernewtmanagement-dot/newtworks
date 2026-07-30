-- ==========================================================================
-- Destructive cleanup: 23 dup credit_transactions rows created 2026-07-28.
-- 8 groups. Same (account, date, amount, description). All NULL source_document_id.
-- 
-- Two failure modes across the groups:
-- 1. Seven groups: each dup ledger row has its OWN journal_entry — P&L
--    over-counted by (N-1) × amount. Total bloat: $439.76.
-- 2. One group (2026-05-09 Plarium x5): all 5 rows share ONE journal_entry —
--    P&L is correct, only the ledger view over-counts. Delete 4 phantom rows
--    but keep the shared JE (canonical row uses it).
--
-- Cleanup: per group, keep earliest-created row + its JE. Delete every other
-- row, and delete its owned JE + journal_lines (unless the JE is shared with
-- the canonical row).
-- ==========================================================================

WITH dup_group_members AS (
  SELECT 
    ct.id AS ledger_id,
    ct.journal_entry_id AS je_id,
    ct.created_at,
    ROW_NUMBER() OVER (
      PARTITION BY ct.agency_id, ct.credit_account_id, ct.transaction_date, ct.amount, ct.description
      ORDER BY ct.created_at
    ) AS rn,
    (COUNT(*) OVER (
      PARTITION BY ct.agency_id, ct.credit_account_id, ct.transaction_date, ct.amount, ct.description
    ))::int AS group_n
  FROM public.credit_transactions ct
  WHERE ct.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND (ct.agency_id, ct.credit_account_id, ct.transaction_date, ct.amount, ct.description) IN (
      SELECT agency_id, credit_account_id, transaction_date, amount, description
      FROM public.credit_transactions
      WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
      GROUP BY agency_id, credit_account_id, transaction_date, amount, description
      HAVING count(*) > 1
    )
),
canonicals AS (SELECT je_id FROM dup_group_members WHERE rn = 1),
non_canonicals AS (SELECT ledger_id, je_id FROM dup_group_members WHERE rn > 1),
jes_to_delete AS (
  SELECT DISTINCT nc.je_id 
  FROM non_canonicals nc
  WHERE nc.je_id IS NOT NULL
    AND nc.je_id NOT IN (SELECT je_id FROM canonicals WHERE je_id IS NOT NULL)
),
del_lines AS (
  DELETE FROM public.journal_lines jl
  WHERE jl.journal_entry_id IN (SELECT je_id FROM jes_to_delete)
  RETURNING jl.id
),
del_ct AS (
  DELETE FROM public.credit_transactions ct
  WHERE ct.id IN (SELECT ledger_id FROM non_canonicals)
  RETURNING ct.id
),
del_je AS (
  DELETE FROM public.journal_entries je
  WHERE je.id IN (SELECT je_id FROM jes_to_delete)
  RETURNING je.id
)
SELECT 
  (SELECT count(*) FROM del_ct) AS ledger_rows_deleted,
  (SELECT count(*) FROM del_je) AS journal_entries_deleted,
  (SELECT count(*) FROM del_lines) AS journal_lines_deleted;
