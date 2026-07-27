-- Archive + purge prior_year_pl 2026 rows (redundant with journal_entries under single-ledger model)

DROP TABLE IF EXISTS public.prior_year_pl_archive_20260727;

CREATE TABLE public.prior_year_pl_archive_20260727 AS
SELECT
  id, agency_id, business_entity_id, period_year, period_month, period_end,
  is_partial_period, period_actual_end_date, section, section_type,
  account_name, amount, source_entity, source_document_id, imported_at
FROM public.prior_year_pl
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND period_end >= '2026-01-01';

DO $$
DECLARE v_source int; v_archive int;
BEGIN
  SELECT COUNT(*) INTO v_source FROM public.prior_year_pl
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid AND period_end >= '2026-01-01';
  SELECT COUNT(*) INTO v_archive FROM public.prior_year_pl_archive_20260727;
  IF v_source != v_archive THEN RAISE EXCEPTION 'archive mismatch % vs %', v_source, v_archive; END IF;
END $$;

DELETE FROM public.prior_year_pl
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid
  AND period_end >= '2026-01-01';
