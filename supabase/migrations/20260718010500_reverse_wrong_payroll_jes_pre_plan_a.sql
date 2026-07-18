-- Migration: reverse_wrong_payroll_jes_pre_plan_a
-- Applied 2026-07-18 via Supabase MCP.
-- Purpose: Reverse the 3 pre-Plan-A payroll JEs (2026-06-27, 2026-07-04, 2026-07-11).
-- These booked everything to COA-SUB-078 lump vs new Plan A structure. Post opposite-sign
-- reversal JEs referencing originals, then NULL out payroll_runs.journal_entry_id + posted_at
-- so payroll_gl_writer can re-post fresh.

DO $$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_agency_entity uuid := 'b2222222-2222-2222-2222-222222222222';
  v_wrong_je uuid;
  v_wrong_je_date date;
  v_wrong_je_desc text;
  v_wrong_je_ref text;
  v_reversal_je uuid;
  v_line record;
BEGIN
  FOREACH v_wrong_je IN ARRAY ARRAY[
    'f7d93b33-d803-4b92-bd20-8e122c356243'::uuid,  -- 2026-06-27
    '66196035-59b9-4604-80f4-0748814a4387'::uuid,  -- 2026-07-04
    '86d882eb-a941-4e26-aa28-76b6c184fabf'::uuid   -- 2026-07-11
  ] LOOP
    SELECT entry_date, description, reference_number
      INTO v_wrong_je_date, v_wrong_je_desc, v_wrong_je_ref
      FROM journal_entries WHERE id = v_wrong_je;

    INSERT INTO journal_entries (
      agency_id, entry_date, description, source, reference_number,
      classification_status, created_at, business_entity_id
    ) VALUES (
      v_agency_id, v_wrong_je_date,
      'REVERSAL of ' || v_wrong_je_ref || ' (Plan A restructure — original booked lump-sum to COA-SUB-078, replaced by split Growth/Team Budget + PaperNewt-side split)',
      'payroll_gl_writer_reversal',
      'REVERSE-' || v_wrong_je_ref,
      'classified', NOW(), v_agency_entity
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
      SET description = description || ' [VOIDED — reversed by REVERSE-' || v_wrong_je_ref || '; replaced by Plan A JEs, see PAYROLL-*-AGENCY / PAYROLL-*-PAPERNEWT for same run_id]'
      WHERE id = v_wrong_je;
  END LOOP;

  UPDATE payroll_runs
    SET journal_entry_id = NULL,
        posted_at = NULL,
        notes = COALESCE(notes,'') || ' [pre-Plan-A JE reversed ' || NOW()::text || '; awaiting fresh post]'
    WHERE agency_id = v_agency_id
      AND pay_period_end IN ('2026-06-27','2026-07-04','2026-07-11');
END $$;
