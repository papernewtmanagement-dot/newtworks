-- Reverse the 9 existing JEs across 3 Plan A payroll runs (AGENCY, PAPERNEWT, PAPERNEWT-IC-RECON per run).
-- Post-reversal, migration 20260719000500 renames originals with -VOIDED-remap suffix and clears
-- payroll_runs so payroll_gl_writer can repost with the new legacy-key mapping + BONUS→variable classification.

WITH originals AS (
  SELECT id, entry_date, reference_number, description, business_entity_id
  FROM public.journal_entries
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND reference_number IN (
      'PAYROLL-e038021d-87fa-4d95-a7d2-65e3d3940af6-AGENCY',
      'PAYROLL-e038021d-87fa-4d95-a7d2-65e3d3940af6-PAPERNEWT',
      'PAYROLL-e038021d-87fa-4d95-a7d2-65e3d3940af6-PAPERNEWT-IC-RECON',
      'PAYROLL-02fe6bec-3c0b-4ee7-9a44-4da665979360-AGENCY',
      'PAYROLL-02fe6bec-3c0b-4ee7-9a44-4da665979360-PAPERNEWT',
      'PAYROLL-02fe6bec-3c0b-4ee7-9a44-4da665979360-PAPERNEWT-IC-RECON',
      'PAYROLL-f486a219-a827-41d7-82ab-46d4ec02a3bc-AGENCY',
      'PAYROLL-f486a219-a827-41d7-82ab-46d4ec02a3bc-PAPERNEWT',
      'PAYROLL-f486a219-a827-41d7-82ab-46d4ec02a3bc-PAPERNEWT-IC-RECON'
    )
),
reversal_je AS (
  INSERT INTO public.journal_entries (
    agency_id, entry_date, reference_number, description, source,
    classification_status, business_entity_id
  )
  SELECT
    '126794dd-25ff-47d2-a436-724499733365'::uuid,
    o.entry_date,
    'REVERSE-' || o.reference_number || '-remap',
    'REVERSAL of ' || o.reference_number || ' (Plan A legacy key mapping + BONUS→variable remap 2026-07-19)',
    'payroll_gl_writer_remap',
    'classified',
    o.business_entity_id
  FROM originals o
  RETURNING id, reference_number
),
reversal_lines AS (
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  SELECT
    r.id,
    '126794dd-25ff-47d2-a436-724499733365'::uuid,
    jl.account_id,
    jl.credit AS debit,
    jl.debit AS credit,
    'REVERSAL: ' || jl.description,
    jl.business_entity_id
  FROM reversal_je r
  JOIN originals o ON ('REVERSE-' || o.reference_number || '-remap') = r.reference_number
  JOIN public.journal_lines jl ON jl.journal_entry_id = o.id
  RETURNING journal_entry_id
)
SELECT (SELECT COUNT(*) FROM reversal_je) AS reversal_je_count,
       (SELECT COUNT(*) FROM reversal_lines) AS reversal_line_count;
