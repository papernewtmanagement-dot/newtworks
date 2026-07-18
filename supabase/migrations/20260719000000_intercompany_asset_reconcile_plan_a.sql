-- Intercompany reconciliation for Plan A payroll (2026-07-19)
-- Agency has $15,243.47 credit balance in COA-IC-001 "Due to PaperNewt".
-- PaperNewt is missing the offsetting asset side. Create COA-IC-002 + backfill 3 JEs.

INSERT INTO public.chart_of_accounts (
  agency_id, account_code, account_name, account_type, account_subtype,
  is_active, is_system, chart_namespace, business_entity_id
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'COA-IC-002',
  'Due from Peter Story State Farm (intercompany)',
  'asset',
  'intercompany_receivable; mirrors COA-IC-001 on agency; two-entity payroll convention',
  true,
  true,
  'historical',
  'b1111111-1111-1111-1111-111111111111'::uuid
)
ON CONFLICT DO NOTHING;

WITH new_ic_asset AS (
  SELECT id FROM public.chart_of_accounts
  WHERE account_code='COA-IC-002' AND business_entity_id='b1111111-1111-1111-1111-111111111111'::uuid
),
je_run1 AS (
  INSERT INTO public.journal_entries (
    agency_id, entry_date, reference_number, description, source,
    classification_status, business_entity_id
  ) VALUES (
    '126794dd-25ff-47d2-a436-724499733365'::uuid,
    '2026-07-03',
    'PAYROLL-e038021d-87fa-4d95-a7d2-65e3d3940af6-PAPERNEWT-IC-RECON',
    'Intercompany receivable — reconciling PaperNewt cash-out vs agency payroll split for run 2026-06-21 to 2026-06-27 (check 2026-07-03)',
    'payroll_gl_writer_ic_backfill',
    'classified',
    'b1111111-1111-1111-1111-111111111111'::uuid
  ) RETURNING id
),
je_run2 AS (
  INSERT INTO public.journal_entries (
    agency_id, entry_date, reference_number, description, source,
    classification_status, business_entity_id
  ) VALUES (
    '126794dd-25ff-47d2-a436-724499733365'::uuid,
    '2026-07-10',
    'PAYROLL-02fe6bec-3c0b-4ee7-9a44-4da665979360-PAPERNEWT-IC-RECON',
    'Intercompany receivable — reconciling PaperNewt cash-out vs agency payroll split for run 2026-06-28 to 2026-07-04 (check 2026-07-10)',
    'payroll_gl_writer_ic_backfill',
    'classified',
    'b1111111-1111-1111-1111-111111111111'::uuid
  ) RETURNING id
),
je_run3 AS (
  INSERT INTO public.journal_entries (
    agency_id, entry_date, reference_number, description, source,
    classification_status, business_entity_id
  ) VALUES (
    '126794dd-25ff-47d2-a436-724499733365'::uuid,
    '2026-07-17',
    'PAYROLL-f486a219-a827-41d7-82ab-46d4ec02a3bc-PAPERNEWT-IC-RECON',
    'Intercompany receivable — reconciling PaperNewt cash-out vs agency payroll split for run 2026-07-05 to 2026-07-11 (check 2026-07-17)',
    'payroll_gl_writer_ic_backfill',
    'classified',
    'b1111111-1111-1111-1111-111111111111'::uuid
  ) RETURNING id
),
insert_run1_lines AS (
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  SELECT je_run1.id, '126794dd-25ff-47d2-a436-724499733365'::uuid, new_ic_asset.id, 4188.57, 0,
         'Due from Story Agency — agency-side team pay 2026-06-21 to 2026-06-27',
         'b1111111-1111-1111-1111-111111111111'::uuid
  FROM je_run1, new_ic_asset
  UNION ALL
  SELECT je_run1.id, '126794dd-25ff-47d2-a436-724499733365'::uuid, 'b022c53c-fec7-4395-940d-e5818ff9242c'::uuid, 0, 4188.57,
         'PaperNewt cash paid out for agency-side team pay 2026-06-21 to 2026-06-27',
         'b1111111-1111-1111-1111-111111111111'::uuid
  FROM je_run1
  RETURNING 1
),
insert_run2_lines AS (
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  SELECT je_run2.id, '126794dd-25ff-47d2-a436-724499733365'::uuid, new_ic_asset.id, 5759.84, 0,
         'Due from Story Agency — agency-side team pay 2026-06-28 to 2026-07-04',
         'b1111111-1111-1111-1111-111111111111'::uuid
  FROM je_run2, new_ic_asset
  UNION ALL
  SELECT je_run2.id, '126794dd-25ff-47d2-a436-724499733365'::uuid, 'b022c53c-fec7-4395-940d-e5818ff9242c'::uuid, 0, 5759.84,
         'PaperNewt cash paid out for agency-side team pay 2026-06-28 to 2026-07-04',
         'b1111111-1111-1111-1111-111111111111'::uuid
  FROM je_run2
  RETURNING 1
),
insert_run3_lines AS (
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  SELECT je_run3.id, '126794dd-25ff-47d2-a436-724499733365'::uuid, new_ic_asset.id, 5295.06, 0,
         'Due from Story Agency — agency-side team pay 2026-07-05 to 2026-07-11',
         'b1111111-1111-1111-1111-111111111111'::uuid
  FROM je_run3, new_ic_asset
  UNION ALL
  SELECT je_run3.id, '126794dd-25ff-47d2-a436-724499733365'::uuid, 'b022c53c-fec7-4395-940d-e5818ff9242c'::uuid, 0, 5295.06,
         'PaperNewt cash paid out for agency-side team pay 2026-07-05 to 2026-07-11',
         'b1111111-1111-1111-1111-111111111111'::uuid
  FROM je_run3
  RETURNING 1
)
SELECT
  (SELECT COUNT(*) FROM insert_run1_lines) AS r1_lines,
  (SELECT COUNT(*) FROM insert_run2_lines) AS r2_lines,
  (SELECT COUNT(*) FROM insert_run3_lines) AS r3_lines;
