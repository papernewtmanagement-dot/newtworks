-- =====================================================================
-- Phase 4k: Citi 1247 = personal CC used for PaperNewt printing expenses (COGS)
-- + Classify 8 mystery deposits per Alvi
-- =====================================================================
-- Notes:
--   Citi 1247 was mis-set-up on PaperNewt entity. Moved to personal.
--   Charges = PN printed products for resale (COGS). Personal card, biz charges.
--   Personal side: DR "PN owes me" (9971), CR Citi 1247
--   PN mirror:     DR Print COGS,          CR "Owed to Peter" (IC-003)
--   Bank payments to Citi -> Internal Transfers (match to CC-side payment JEs)
--   Missing Citi statement covers the 3/19 bank withdrawal of $204.45 (dangling)
--
--   PayPal $1000 deposit into personal 2545 = PN print sales revenue.
--   Personal: DR bank, CR "Cash held for PN" (9972 liability)
--   PN mirror: DR "Cash held at Personal" (IC-004 asset), CR Print Sales Revenue
--
--   Richard's rent $2K into RBFCU 6596 -> new Rental Income category (8500)
--   Foster Post Adoption reimbursement $250 -> Foster Care (nontaxable)
--   Lightshine deposits (4x, small mobile checks) -> Other Personal Income
--   Pedernales Electric refund $22.23 -> Other Personal Income
-- =====================================================================

DO $pf4k$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id UUID := 'b3333333-3333-3333-3333-333333333333';
  v_pn_id UUID := 'b1111111-1111-1111-1111-111111111111';
  v_citi_ca_id UUID;
  v_citi_coa_id UUID;
  v_pn_cogs_id UUID;
  v_pn_print_rev_id UUID;
  v_pn_ic_asset_id UUID;
  v_reimb_pers_id UUID;
  v_owed_to_peter_id UUID;
  v_owed_to_pn_id UUID;
  v_rental_income_id UUID;
  v_transfers_id UUID;
  v_susp_out_id UUID;
  v_susp_in_id UUID;
  v_other_income_id UUID;
  v_foster_income_id UUID;
  v_txn RECORD;
  v_je_id UUID;
  v_amt NUMERIC;
BEGIN
  SELECT id INTO v_citi_ca_id FROM public.credit_accounts WHERE account_number_last4 = '1247';
  UPDATE public.credit_accounts SET business_entity_id = v_pers_id WHERE id = v_citi_ca_id;
  UPDATE public.credit_transactions SET business_entity_id = v_pers_id WHERE credit_account_id = v_citi_ca_id;

  INSERT INTO public.chart_of_accounts (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES
    (v_agency_id, v_pers_id, 'COA-PERSONAL-CC-1247', 'Citi Personal CC (1247) — PaperNewt printing card', 'liability', 'credit_card', 'active', true, false),
    (v_agency_id, v_pers_id, 'COA-PERSONAL-9972', 'Cash held for PaperNewt (owed back)', 'liability', 'intercompany', 'active', true, true),
    (v_agency_id, v_pers_id, 'COA-PERSONAL-8500', 'Rental Income', 'income', 'rental', 'active', true, false),
    (v_agency_id, v_pn_id, 'COA-PN-COGS-PRINT', 'Printed Products for Resale (COGS)', 'expense', 'cogs', 'active', true, false),
    (v_agency_id, v_pn_id, 'COA-PN-REVENUE-PRINT', 'Print Sales Revenue', 'income', 'sales', 'active', true, false),
    (v_agency_id, v_pn_id, 'COA-PN-IC-004', 'Cash held at Personal (from PN sales)', 'asset', 'intercompany', 'active', true, true)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  SELECT id INTO v_citi_coa_id      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-1247';
  SELECT id INTO v_pn_cogs_id       FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-COGS-PRINT';
  SELECT id INTO v_pn_print_rev_id  FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-REVENUE-PRINT';
  SELECT id INTO v_pn_ic_asset_id   FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-IC-004';
  SELECT id INTO v_reimb_pers_id    FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9971';
  SELECT id INTO v_owed_to_peter_id FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-IC-003';
  SELECT id INTO v_owed_to_pn_id    FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9972';
  SELECT id INTO v_rental_income_id FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-8500';
  SELECT id INTO v_transfers_id     FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9990';
  SELECT id INTO v_susp_out_id      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9999';
  SELECT id INTO v_susp_in_id       FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-8999';
  SELECT id INTO v_other_income_id  FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-8300';
  SELECT id INTO v_foster_income_id FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-8400';

  UPDATE public.credit_accounts SET chart_account_id = v_citi_coa_id WHERE id = v_citi_ca_id;

  FOR v_txn IN SELECT id, transaction_date, description, amount FROM public.credit_transactions
    WHERE credit_account_id = v_citi_ca_id AND journal_entry_id IS NULL ORDER BY transaction_date, id
  LOOP
    v_amt := ABS(v_txn.amount);
    IF v_txn.amount < 0 THEN
      INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
      VALUES (v_agency_id, v_pers_id, v_txn.transaction_date, 'personal_credit', 'CITI 1247: ' || v_txn.description, 'pf4k_citi_ingest', 'classified', 'phase_4k_migration', 'Payment received on Citi 1247; mirrors bank withdrawal') RETURNING id INTO v_je_id;
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_citi_coa_id, v_amt, 0, v_txn.description, v_pers_id);
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_transfers_id, 0, v_amt, v_txn.description, v_pers_id);
    ELSE
      INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
      VALUES (v_agency_id, v_pers_id, v_txn.transaction_date, 'personal_credit', 'CITI 1247: ' || v_txn.description, 'pf4k_citi_ingest', 'classified', 'phase_4k_migration', 'PN printing supplies for resale on personal Citi 1247; PN owes Peter back') RETURNING id INTO v_je_id;
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_reimb_pers_id, v_amt, 0, v_txn.description, v_pers_id);
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_citi_coa_id, 0, v_amt, v_txn.description, v_pers_id);
      INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
      VALUES (v_agency_id, v_pn_id, v_txn.transaction_date, 'personal_paid_biz_expense', 'PN PRINT COGS: ' || v_txn.description, 'pf4k_citi_ingest', 'classified', 'phase_4k_migration', 'Printed products for resale purchased on Peter personal Citi 1247') RETURNING id INTO v_je_id;
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_pn_cogs_id, v_amt, 0, v_txn.description, v_pn_id);
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_owed_to_peter_id, 0, v_amt, v_txn.description, v_pn_id);
    END IF;
    UPDATE public.credit_transactions SET journal_entry_id = v_je_id WHERE id = v_txn.id;
  END LOOP;

  UPDATE public.journal_lines SET account_id = v_transfers_id
   WHERE journal_entry_id IN (SELECT bt.journal_entry_id FROM public.bank_transactions bt WHERE bt.business_entity_id = v_pers_id AND bt.description ILIKE '%CITI%')
     AND account_id = v_susp_out_id;
  UPDATE public.journal_entries je SET classification_status = 'classified', classified_by='pf4k_citi_reclass', classified_at=NOW(),
       memo = COALESCE(memo || ' | ', '') || 'Reclass: bank -> Citi 1247 = CC payment'
   WHERE je.id IN (SELECT bt.journal_entry_id FROM public.bank_transactions bt WHERE bt.business_entity_id = v_pers_id AND bt.description ILIKE '%CITI%');

  UPDATE public.journal_lines SET account_id = v_other_income_id
   WHERE journal_entry_id IN (SELECT journal_entry_id FROM public.bank_transactions WHERE id IN
     ('9da87a4f-208c-4a32-91b0-03dcb92094ab','66bc0cad-d16d-43a0-b985-d73fc789df13',
      '845694bf-582c-4d0e-832b-6dc279400b93','5a193893-b531-4e77-9437-97c763b568d8'))
     AND account_id = v_susp_in_id;

  UPDATE public.journal_lines SET account_id = v_rental_income_id
   WHERE journal_entry_id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = '1f369c69-cbad-4807-8dd4-cf540973b020')
     AND account_id = v_susp_in_id;

  UPDATE public.journal_lines SET account_id = v_foster_income_id
   WHERE journal_entry_id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = 'b5c92fe9-42e9-4d0c-8951-8ac42de83220')
     AND account_id = v_susp_in_id;

  UPDATE public.journal_lines SET account_id = v_owed_to_pn_id
   WHERE journal_entry_id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = 'ff130e67-46f2-4149-8439-435e6d147911')
     AND account_id = v_susp_in_id;

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pn_id, '2026-05-29', 'intercompany_revenue', 'PN PRINT SALES: PayPal transfer into Peter personal 2545',
          'pf4k_paypal_pn_sales', 'classified', 'phase_4k_migration', 'Customer paid via PayPal for PN print sale; cash landed in personal 2545')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_pn_ic_asset_id, 1000.00, 0, 'Cash held at Personal from PN sale', v_pn_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_pn_print_rev_id, 0, 1000.00, 'PayPal customer payment', v_pn_id);

  UPDATE public.journal_lines SET account_id = v_other_income_id
   WHERE journal_entry_id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = 'd0b6ff66-5477-49aa-81af-1e80fa1ee285')
     AND account_id = v_susp_in_id;

  UPDATE public.journal_entries SET memo = 'Lightshine (4/20 $65)', classified_by='pf4k_deposits_alvi', classified_at=NOW(), classification_status='classified'
   WHERE id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = '9da87a4f-208c-4a32-91b0-03dcb92094ab');
  UPDATE public.journal_entries SET memo = 'Lightshine (4/23 $90)', classified_by='pf4k_deposits_alvi', classified_at=NOW(), classification_status='classified'
   WHERE id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = '66bc0cad-d16d-43a0-b985-d73fc789df13');
  UPDATE public.journal_entries SET memo = 'Richard rent (cash deposited to RBFCU savings 6596)', classified_by='pf4k_deposits_alvi', classified_at=NOW(), classification_status='classified'
   WHERE id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = '1f369c69-cbad-4807-8dd4-cf540973b020');
  UPDATE public.journal_entries SET memo = 'Lightshine (5/15 $90 REF=9252925424)', classified_by='pf4k_deposits_alvi', classified_at=NOW(), classification_status='classified'
   WHERE id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = '845694bf-582c-4d0e-832b-6dc279400b93');
  UPDATE public.journal_entries SET memo = 'Lightshine (5/15 $90 REF=9252925235) — assumed Lightshine (Peter identified one 5/15 $90)', classified_by='pf4k_deposits_alvi', classified_at=NOW(), classification_status='classified'
   WHERE id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = '5a193893-b531-4e77-9437-97c763b568d8');
  UPDATE public.journal_entries SET memo = 'Post Adoption reimbursement (5/15 $250)', classified_by='pf4k_deposits_alvi', classified_at=NOW(), classification_status='classified'
   WHERE id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = 'b5c92fe9-42e9-4d0c-8951-8ac42de83220');
  UPDATE public.journal_entries SET memo = 'PN print sale via PayPal; cash held in personal 2545 (intercompany)', classified_by='pf4k_deposits_alvi', classified_at=NOW(), classification_status='classified'
   WHERE id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = 'ff130e67-46f2-4149-8439-435e6d147911');
  UPDATE public.journal_entries SET memo = 'Pedernales Electric refund (from Austin utility)', classified_by='pf4k_deposits_alvi', classified_at=NOW(), classification_status='classified'
   WHERE id = (SELECT journal_entry_id FROM public.bank_transactions WHERE id = 'd0b6ff66-5477-49aa-81af-1e80fa1ee285');
END $pf4k$;

INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_source_account, match_direction,
   debit_account_code, credit_account_code, sub_category_label, confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'ND4C Houston -> PN Print COGS (Citi 1247 only)',    110, '(?i)ND4C\s+HOUSTON', 'COA-PERSONAL-CC-1247', 'debit', 'COA-PERSONAL-9971', '__SOURCE__', 'PN printing supplies for resale (owed back)', 'exact', 'pf4k_citi_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Bank paying Citi 1247 -> Internal Transfers',       100, '(?i)Electronic\s+Withdrawal\s+To\s+CITI', NULL, 'debit', 'COA-PERSONAL-9990', '__SOURCE__', 'CC Payment', 'exact', 'pf4k_citi_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Citi ONLINE PAYMENT THANK YOU -> Internal Transfers', 100, '(?i)ONLINE\s+PAYMENT,\s*THANK\s+YOU', 'COA-PERSONAL-CC-1247', 'credit', '__SOURCE__', 'COA-PERSONAL-9990', 'CC Payment', 'exact', 'pf4k_citi_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Post Adoption reimbursement -> Foster Care',        100, '(?i)POST\s+ADOPTION', NULL, 'credit', '__SOURCE__', 'COA-PERSONAL-8400', 'Foster Care Income (nontaxable)', 'exact', 'pf4k_deposits_seed', true);
