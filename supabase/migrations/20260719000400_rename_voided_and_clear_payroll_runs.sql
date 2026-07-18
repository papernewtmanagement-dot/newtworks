-- Rename the 9 originals with -VOIDED-remap suffix so writer's reference_number won't collide on repost.
UPDATE public.journal_entries
SET reference_number = reference_number || '-VOIDED-remap',
    description = description || ' [VOIDED — legacy key remap 2026-07-19; reversed by REVERSE-*-remap; will be replaced by fresh writer post]'
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
  );

-- Clear payroll_runs.journal_entry_id + posted_at so writer will re-process the 3 runs
UPDATE public.payroll_runs
SET journal_entry_id = NULL,
    posted_at = NULL,
    notes = COALESCE(notes,'') || ' [cleared for legacy-key remap repost 2026-07-19]'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND id IN (
    'e038021d-87fa-4d95-a7d2-65e3d3940af6'::uuid,
    '02fe6bec-3c0b-4ee7-9a44-4da665979360'::uuid,
    'f486a219-a827-41d7-82ab-46d4ec02a3bc'::uuid
  );

-- After this migration, writer is invoked via:
--   SELECT public.payroll_gl_writer('126794dd-25ff-47d2-a436-724499733365'::uuid, false, NULL::date);
-- to repost the 3 runs with new classification. Live invocation done via execute_sql
-- rather than embedded here so JSONB return value is captured for verification.
