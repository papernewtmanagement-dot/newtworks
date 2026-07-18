-- Migration: reverse_incomplete_plan_a_je_2026_07_04
-- Applied 2026-07-18 via Supabase MCP.
-- Purpose: The 2026-07-04 payroll_detail rows use legacy raw_earnings key schema
-- (REGULAR/2Serve/3True/5Goals/etc). First Plan A post dropped ~$3,325 of items on the floor.
-- Reverse both fresh JEs (agency + PN) and let the patched writer re-post with gap-catcher logic.

DO $$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_agency_entity uuid := 'b2222222-2222-2222-2222-222222222222';
  v_papernewt_entity uuid := 'b1111111-1111-1111-1111-111111111111';
  v_wrong_je uuid;
  v_wrong_je_date date;
  v_wrong_je_desc text;
  v_wrong_je_ref text;
  v_wrong_je_entity uuid;
  v_reversal_je uuid;
  v_line record;
BEGIN
  FOREACH v_wrong_je IN ARRAY ARRAY[
    '4cc7db92-7209-4364-bae8-1876f2e13567'::uuid,  -- agency-side 2026-07-04 fresh JE
    'f6138f67-3b04-49a8-b48d-3612cee74d8b'::uuid   -- PN-side 2026-07-04 fresh JE
  ] LOOP
    SELECT entry_date, description, reference_number, business_entity_id
      INTO v_wrong_je_date, v_wrong_je_desc, v_wrong_je_ref, v_wrong_je_entity
      FROM journal_entries WHERE id = v_wrong_je;

    INSERT INTO journal_entries (
      agency_id, entry_date, description, source, reference_number,
      classification_status, created_at, business_entity_id
    ) VALUES (
      v_agency_id, v_wrong_je_date,
      'REVERSAL of ' || v_wrong_je_ref || ' (Plan A first-post dropped legacy items; re-posting with gap-catcher)',
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
      SET description = description || ' [VOIDED — reversed by REVERSE-' || v_wrong_je_ref || '; replaced by gap-catcher re-post]'
      WHERE id = v_wrong_je;
  END LOOP;

  UPDATE payroll_runs
    SET journal_entry_id = NULL,
        posted_at = NULL,
        notes = COALESCE(notes,'') || ' [fresh Plan A JE reversed ' || NOW()::text || ' due to legacy-key gap; awaiting gap-catcher re-post]'
    WHERE agency_id = v_agency_id
      AND pay_period_end = '2026-07-04';
END $$;
