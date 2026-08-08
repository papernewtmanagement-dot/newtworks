-- Flat snapshot of the P&L table as it stands immediately before the wipe.
-- Read-only forensic record: what was posted, by which writer, against which account,
-- and which statement/document it came from. Not read by any live code.
CREATE TABLE IF NOT EXISTS public.ledger_prewipe_archive_20260807 AS
SELECT
  jl.id                AS line_id,
  jl.journal_entry_id,
  jl.agency_id,
  jl.entry_date,
  je.description       AS entry_description,
  jl.description       AS line_description,
  jl.memo,
  jl.source,
  jl.entry_type,
  jl.reference_number,
  jl.debit,
  jl.credit,
  jl.account_id,
  coa.account_code,
  coa.account_name,
  be.name             AS entity,
  jl.statement_id,
  jl.document_id,
  jl.classification_status,
  jl.suspense_reason,
  jl.rule_id_used,
  jl.classified_by,
  jl.original_account_id,
  jl.original_account_code,
  jl.original_account_name,
  jl.reclassification_id,
  jl.created_at
FROM public.journal_lines jl
LEFT JOIN public.journal_entries je ON je.id = jl.journal_entry_id
LEFT JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
LEFT JOIN public.business_entities be ON be.id = coa.business_entity_id;

CREATE INDEX IF NOT EXISTS idx_ledger_prewipe_source ON public.ledger_prewipe_archive_20260807(source);
CREATE INDEX IF NOT EXISTS idx_ledger_prewipe_date ON public.ledger_prewipe_archive_20260807(entry_date);

ALTER TABLE public.ledger_prewipe_archive_20260807 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ledger_prewipe_archive_20260807 FROM anon, PUBLIC;
GRANT SELECT ON public.ledger_prewipe_archive_20260807 TO authenticated;

DROP POLICY IF EXISTS ledger_prewipe_ro ON public.ledger_prewipe_archive_20260807;
CREATE POLICY ledger_prewipe_ro ON public.ledger_prewipe_archive_20260807
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- also snapshot the 69 transaction tags, which cascade-delete with the lines
CREATE TABLE IF NOT EXISTS public.transaction_tags_prewipe_archive_20260807 AS
SELECT * FROM public.transaction_tags;
ALTER TABLE public.transaction_tags_prewipe_archive_20260807 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.transaction_tags_prewipe_archive_20260807 FROM anon, PUBLIC;
GRANT SELECT ON public.transaction_tags_prewipe_archive_20260807 TO authenticated;