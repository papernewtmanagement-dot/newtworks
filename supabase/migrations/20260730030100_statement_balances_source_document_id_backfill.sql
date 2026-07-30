-- ==========================================================================
-- statement_balances.source_document_id backfill (Item 2 of guard follow-ups)
--
-- Backfill for rows that unambiguously match a documents row by
-- (agency_id, account_code, filename containing period YY-MM).
--
-- Historical background: 57 NULL rows existed as of 2026-07-30. Investigation
-- showed 8 rows had unambiguous 1-to-1 doc matches (COA-PERSONAL-0353 x1,
-- COA-PERSONAL-2545 x7). The remaining 49 rows have no candidate documents —
-- those statements were ingested via chat backfill or zip-content extract
-- paths that bypassed insertSourceDocument. Grandfathered as legit-NULL.
--
-- Parser paths (Gmail intake -> handleBankStatement -> writeStatementBalance)
-- already require documentId, so no forward-enforcement change needed.
-- Manual/chat writers must remember to populate source_document_id — for now
-- enforced by convention, not constraint.
-- ==========================================================================

WITH null_sb AS (
  SELECT sb.id as sb_id, sb.account_code, sb.statement_period_end,
         to_char(sb.statement_period_end, 'YY-MM') as period_yymm
  FROM public.statement_balances sb
  WHERE sb.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND sb.source_document_id IS NULL
    AND sb.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-2545')
),
resolved AS (
  SELECT n.sb_id, d.id as doc_id
  FROM null_sb n
  JOIN public.documents d
    ON d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND d.source_account_code = n.account_code
   AND d.file_name ILIKE '%' || n.period_yymm || '%'
)
UPDATE public.statement_balances sb
SET source_document_id = r.doc_id,
    notes = COALESCE(sb.notes || E'\n', '') || '[backfill 2026-07-30] source_document_id linked from documents match'
FROM resolved r
WHERE sb.id = r.sb_id;
