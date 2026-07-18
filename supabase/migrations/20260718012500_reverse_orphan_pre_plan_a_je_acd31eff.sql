-- Migration: reverse_orphan_pre_plan_a_je_acd31eff
-- Applied 2026-07-18 via Supabase MCP.
-- Purpose: Orphan JE 57facd1b (reference PAYROLL-acd31eff...) was posted against a defunct
-- payroll_run_id from an earlier 2026-07-04 ingest attempt. Payroll_runs was
-- re-ingested with new UUID 02fe6bec, leaving 57facd1b double-booked in the ledger.
-- Reverse it same as the other pre-Plan-A wrong JEs.

DO $$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_wrong_je uuid := '57facd1b-ac07-4440-8dd3-262f89c1b3a1';
  v_wrong_je_date date;
  v_wrong_je_ref text;
  v_wrong_je_entity uuid;
  v_reversal_je uuid;
  v_line record;
BEGIN
  SELECT entry_date, reference_number, business_entity_id
    INTO v_wrong_je_date, v_wrong_je_ref, v_wrong_je_entity
    FROM journal_entries WHERE id = v_wrong_je;

  INSERT INTO journal_entries (
    agency_id, entry_date, description, source, reference_number,
    classification_status, created_at, business_entity_id
  ) VALUES (
    v_agency_id, v_wrong_je_date,
    'REVERSAL of ' || v_wrong_je_ref || ' (orphan JE from defunct 2026-07-04 payroll_run acd31eff; double-booking cleanup)',
    'payroll_gl_writer_reversal',
    'REVERSE-' || v_wrong_je_ref,
    'classified', NOW(), v_wrong_je_entity
  ) RETURNING id INTO v_reversal_je;

  FOR v_line IN
    SELECT account_id, debit, credit, description, business_entity_id
      FROM journal_lines WHERE journal_entry_id = v_wrong_je
  LOOP
    INSERT INTO journal_lines (
      journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id
    ) VALUES (
      v_reversal_je, v_agency_id, v_line.account_id,
      v_line.credit, v_line.debit,
      'REVERSAL: ' || COALESCE(v_line.description, ''),
      v_line.business_entity_id
    );
  END LOOP;

  UPDATE journal_entries
    SET description = description || ' [VOIDED — orphan from defunct run acd31eff; reversed by REVERSE-' || v_wrong_je_ref || ']',
        reference_number = reference_number || '-VOIDED-' || substring(v_wrong_je::text, 1, 8)
    WHERE id = v_wrong_je;
END $$;
