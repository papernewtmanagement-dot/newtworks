-- =====================================================================
-- Phase 4c: SMVC TRUCKING deposits -> Eriosto revenue (intercompany)
-- =====================================================================
-- Peter's direction: SMVC pays Eriosto directly. Deposits landing in his
-- personal bank account are Eriosto's revenue, held in personal's cash
-- account. Proper double-entry:
--
-- Personal side (existing JE rewritten):
--   DR PERSONAL-<bank>            (cash arrived, unchanged)
--   CR PERSONAL-9970              (Due to Eriosto — intercompany liability)
--
-- Eriosto side (new mirror JE):
--   DR ERIOSTO-1500               (Due from Personal — intercompany receivable)
--   CR ERIOSTO-4100               (SMVC Trucking Contract Revenue)
-- =====================================================================

DO $smvc$
DECLARE
  v_agency_id     UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id       UUID := 'b3333333-3333-3333-3333-333333333333';
  v_eriosto_id    UUID := 'b5555555-5555-5555-5555-555555555555';
  v_susp_in_id    UUID;
  v_pers_due_to_er UUID;
  v_er_due_from_p  UUID;
  v_er_revenue     UUID;
  v_txn RECORD;
  v_new_je_id UUID;
  v_amt NUMERIC;
BEGIN
  INSERT INTO public.chart_of_accounts
    (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES
    (v_agency_id, v_pers_id, 'PERSONAL-9970', 'Due to Eriosto (intercompany)',
     'liability', 'intercompany', 'active', true, true)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  INSERT INTO public.chart_of_accounts
    (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES
    (v_agency_id, v_eriosto_id, 'ERIOSTO-1500', 'Due from Peter Story (intercompany)',
     'asset', 'intercompany', 'active', true, true),
    (v_agency_id, v_eriosto_id, 'ERIOSTO-4100', 'SMVC Trucking Contract Revenue',
     'income', 'contract_revenue', 'active', true, false)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  SELECT id INTO v_susp_in_id     FROM public.chart_of_accounts
    WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-8999';
  SELECT id INTO v_pers_due_to_er FROM public.chart_of_accounts
    WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-9970';
  SELECT id INTO v_er_due_from_p  FROM public.chart_of_accounts
    WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='ERIOSTO-1500';
  SELECT id INTO v_er_revenue     FROM public.chart_of_accounts
    WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='ERIOSTO-4100';

  FOR v_txn IN
    SELECT bt.id AS bt_id, bt.transaction_date, bt.description, bt.amount,
           bt.journal_entry_id AS pers_je_id
      FROM public.bank_transactions bt
     WHERE bt.business_entity_id = v_pers_id
       AND bt.agency_id = v_agency_id
       AND bt.description ILIKE '%SMVC TRUCKING PAYROLL%'
  LOOP
    v_amt := ABS(v_txn.amount);

    UPDATE public.journal_lines
       SET account_id = v_pers_due_to_er
     WHERE journal_entry_id = v_txn.pers_je_id
       AND account_id = v_susp_in_id
       AND credit = v_amt;

    UPDATE public.journal_entries
       SET classification_status = 'classified',
           classified_by = 'pf4c_smvc_to_eriosto',
           classified_at = NOW(),
           memo = COALESCE(memo || ' | ', '') || 'Reclass: SMVC payment held for Eriosto (intercompany)'
     WHERE id = v_txn.pers_je_id;

    INSERT INTO public.journal_entries
      (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
    VALUES
      (v_agency_id, v_eriosto_id, v_txn.transaction_date, 'intercompany_revenue',
       'ERIOSTO REVENUE: ' || v_txn.description || ' (cash held at Personal ' || v_txn.bt_id::text || ')',
       'pf4c_smvc_to_eriosto', 'classified', 'phase_4c_migration',
       'SMVC payment to Eriosto received in Peter personal bank account')
    RETURNING id INTO v_new_je_id;

    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_new_je_id, v_agency_id, v_er_due_from_p, v_amt, 0,
            'Cash held at Personal from SMVC', v_eriosto_id);
    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_new_je_id, v_agency_id, v_er_revenue, 0, v_amt,
            'SMVC Trucking payment', v_eriosto_id);
  END LOOP;
END
$smvc$;
