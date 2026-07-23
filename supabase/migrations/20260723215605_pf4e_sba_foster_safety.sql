-- Phase 4e: SBA EIDL intercompany + Foster care income (nontaxable) + Home Security & Safety
DO $pf4e$
DECLARE
  v_agency_id     UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id       UUID := 'b3333333-3333-3333-3333-333333333333';
  v_pn_id         UUID := 'b1111111-1111-1111-1111-111111111111';
  v_susp_in_id    UUID;
  v_susp_out_id   UUID;
  v_pers_due_from_pn  UUID;
  v_pn_sba_liab   UUID;
  v_pn_due_to_pers UUID;
  v_foster_income UUID;
  v_safety_id     UUID;
  v_disc_id       UUID;
  v_txn RECORD;
  v_new_je_id UUID;
  v_amt NUMERIC;
BEGIN
  INSERT INTO public.chart_of_accounts
    (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES
    (v_agency_id, v_pers_id, 'PERSONAL-9971', 'Due from PaperNewt (intercompany)',
     'asset', 'intercompany', 'active', true, true),
    (v_agency_id, v_pers_id, 'PERSONAL-8400', 'Foster Care Income (nontaxable)',
     'income', 'foster_care', 'active', true, false),
    (v_agency_id, v_pers_id, 'PERSONAL-9130', 'Home Security & Safety',
     'expense', 'housing', 'active', true, false),
    (v_agency_id, v_pn_id, 'PN-LOAN-SBA-EIDL', 'SBA EIDL Loan (long-term)',
     'liability', 'long_term_debt', 'active', true, false),
    (v_agency_id, v_pn_id, 'COA-IC-003', 'Due to Peter Story (intercompany personal loan repayments)',
     'liability', 'intercompany', 'active', true, true)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  SELECT id INTO v_susp_in_id       FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-8999';
  SELECT id INTO v_susp_out_id      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-9999';
  SELECT id INTO v_pers_due_from_pn FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-9971';
  SELECT id INTO v_pn_sba_liab      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PN-LOAN-SBA-EIDL';
  SELECT id INTO v_pn_due_to_pers   FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-IC-003';
  SELECT id INTO v_foster_income    FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-8400';
  SELECT id INTO v_safety_id        FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-9130';
  SELECT id INTO v_disc_id          FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-9800';

  UPDATE public.journal_lines
     SET account_id = v_foster_income
   WHERE journal_entry_id IN (
     SELECT id FROM public.journal_entries
      WHERE source = 'pf4_personal_backfill'
        AND business_entity_id = v_pers_id
        AND description ILIKE '%FAMILY PROTCT SV%'
   )
     AND account_id = v_susp_in_id;

  UPDATE public.journal_lines
     SET account_id = v_safety_id
   WHERE journal_entry_id IN (
     SELECT id FROM public.journal_entries
      WHERE source = 'pf4_personal_backfill'
        AND business_entity_id = v_pers_id
        AND (description ILIKE '%BUCK AND DOE%' OR description ILIKE '%SP SAFERINGZ%')
   )
     AND account_id = v_disc_id;

  FOR v_txn IN
    SELECT bt.id AS bt_id, bt.transaction_date, bt.description, bt.amount,
           bt.journal_entry_id AS pers_je_id
      FROM public.bank_transactions bt
     WHERE bt.business_entity_id = v_pers_id
       AND bt.agency_id = v_agency_id
       AND bt.description ILIKE '%SBA EIDL LOAN%'
  LOOP
    v_amt := ABS(v_txn.amount);
    UPDATE public.journal_lines
       SET account_id = v_pers_due_from_pn
     WHERE journal_entry_id = v_txn.pers_je_id
       AND account_id = v_susp_out_id
       AND debit = v_amt;
    UPDATE public.journal_entries
       SET classification_status = 'classified',
           classified_by = 'pf4e_sba_eidl_intercompany',
           classified_at = NOW(),
           memo = COALESCE(memo || ' | ', '') || 'Reclass: personal paid PaperNewt SBA loan (intercompany receivable)'
     WHERE id = v_txn.pers_je_id;
    INSERT INTO public.journal_entries
      (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
    VALUES
      (v_agency_id, v_pn_id, v_txn.transaction_date, 'intercompany_loan_pmt',
       'PAPERNEWT SBA LOAN PAYMENT (paid from personal ' || v_txn.bt_id::text || ')',
       'pf4e_sba_eidl_intercompany', 'classified', 'phase_4e_migration',
       'SBA EIDL payment made from Peter personal bank; PaperNewt owes Peter back')
    RETURNING id INTO v_new_je_id;
    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_new_je_id, v_agency_id, v_pn_sba_liab, v_amt, 0, 'SBA EIDL principal + interest', v_pn_id);
    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_new_je_id, v_agency_id, v_pn_due_to_pers, 0, v_amt, 'Owed to Peter for personal-paid loan', v_pn_id);
  END LOOP;

  UPDATE public.journal_entries
     SET classification_status = 'classified',
         classified_by = 'pf4e_foster_care',
         classified_at = NOW()
   WHERE source = 'pf4_personal_backfill'
     AND business_entity_id = v_pers_id
     AND description ILIKE '%FAMILY PROTCT SV%'
     AND classification_status = 'pending_review';
END
$pf4e$;
