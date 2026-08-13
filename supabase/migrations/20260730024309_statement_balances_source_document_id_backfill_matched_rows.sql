-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 02:43:09 UTC (ledger name: statement_balances_source_document_id_backfill_matched_rows) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730024309.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- Backfill statement_balances.source_document_id for rows that unambiguously
-- match a documents row by (agency_id, account_code, filename containing period YY-MM).
-- 
-- Historical background: 57 NULL rows exist as of 2026-07-30. Investigation shows
-- 8 rows have unambiguous 1-to-1 doc matches (COA-PERSONAL-0353 x1, COA-PERSONAL-2545 x7).
-- The remaining 49 rows have no candidate documents at all — those statements were
-- ingested via chat backfill or zip-content extract paths that bypassed insertSourceDocument.
-- Leave those grandfathered as legit-NULL.

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

-- Verify
SELECT 
  (SELECT count(*) FROM public.statement_balances 
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' 
     AND source_document_id IS NULL) as still_null,
  (SELECT count(*) FROM public.statement_balances 
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' 
     AND source_document_id IS NOT NULL) as has_doc;
