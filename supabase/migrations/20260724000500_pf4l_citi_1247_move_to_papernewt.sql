-- =====================================================================
-- Phase 4l: Flip Citi 1247 to PN-owned card (Option B — GAAP-preferred).
-- Card dedicated to PN printing supplies for resale, so treat as PN
-- liability regardless of whose name is on the card.
--
-- Changes vs pf4k:
--   Card + credit_transactions moved back to PN entity
--   New COA: COA-PN-CC-1247 (liability on PN)
--   New COA: COA-PERSONAL-9985 (Owner contributions to PN, personal equity)
--   New COA: COA-PN-EQUITY-CONTRIB (Owner contributions from Peter, PN equity)
--   Old COA-PERSONAL-CC-1247 deactivated
--   4 pf4k CC JEs deleted; charges reposted as PN-only (DR PN COGS, CR PN Citi)
--   3 bank Citi payment JEs flipped: DR was Internal Transfers -> now Owner
--     Contribution equity. Matching PN-side JE created per payment:
--     DR PN Citi (reduce liability), CR PN Owner Contribution equity
--   Classification rules retargeted to PN codes
-- =====================================================================

DO $pf4l$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id UUID := 'b3333333-3333-3333-3333-333333333333';
  v_pn_id UUID := 'b1111111-1111-1111-1111-111111111111';
  v_citi_ca_id UUID;
  v_old_citi_pers_coa UUID;
  v_new_citi_pn_coa UUID;
  v_pn_cogs_id UUID;
  v_owner_contrib_id UUID;
  v_pn_owner_contrib_id UUID;
  v_txn RECORD;
  v_ba RECORD;
  v_je_id UUID;
  v_amt NUMERIC;
BEGIN
  SELECT id INTO v_citi_ca_id FROM public.credit_accounts WHERE account_number_last4 = '1247';
  SELECT id INTO v_old_citi_pers_coa FROM public.chart_of_accounts
    WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-1247';

  INSERT INTO public.chart_of_accounts (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES
    (v_agency_id, v_pn_id, 'COA-PN-CC-1247', 'Citi CC (1247) — PN printing card', 'liability', 'credit_card', 'active', true, false),
    (v_agency_id, v_pers_id, 'COA-PERSONAL-9985', 'Owner contributions to PaperNewt', 'equity', 'owner_contribution', 'active', true, true),
    (v_agency_id, v_pn_id, 'COA-PN-EQUITY-CONTRIB', 'Owner contributions from Peter', 'equity', 'owner_contribution', 'active', true, true)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  SELECT id INTO v_new_citi_pn_coa      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-CC-1247';
  SELECT id INTO v_pn_cogs_id           FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-COGS-PRINT';
  SELECT id INTO v_owner_contrib_id     FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9985';
  SELECT id INTO v_pn_owner_contrib_id  FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-EQUITY-CONTRIB';

  UPDATE public.credit_transactions SET journal_entry_id = NULL WHERE credit_account_id = v_citi_ca_id;
  DELETE FROM public.journal_lines WHERE journal_entry_id IN (SELECT id FROM public.journal_entries WHERE source = 'pf4k_citi_ingest');
  DELETE FROM public.journal_entries WHERE source = 'pf4k_citi_ingest';

  UPDATE public.credit_accounts SET business_entity_id = v_pn_id, chart_account_id = v_new_citi_pn_coa WHERE id = v_citi_ca_id;
  UPDATE public.credit_transactions SET business_entity_id = v_pn_id WHERE credit_account_id = v_citi_ca_id;

  FOR v_txn IN
    SELECT id, transaction_date, description, amount FROM public.credit_transactions
    WHERE credit_account_id = v_citi_ca_id AND journal_entry_id IS NULL AND amount > 0
    ORDER BY transaction_date, id
  LOOP
    v_amt := v_txn.amount;
    INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
    VALUES (v_agency_id, v_pn_id, v_txn.transaction_date, 'business_credit',
            'PN CITI 1247: ' || v_txn.description, 'pf4l_citi_pn', 'classified', 'phase_4l_migration',
            'Printed products for resale, charged to PN Citi 1247')
    RETURNING id INTO v_je_id;
    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_je_id, v_agency_id, v_pn_cogs_id, v_amt, 0, v_txn.description, v_pn_id);
    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_je_id, v_agency_id, v_new_citi_pn_coa, 0, v_amt, v_txn.description, v_pn_id);
    UPDATE public.credit_transactions SET journal_entry_id = v_je_id WHERE id = v_txn.id;
  END LOOP;

  FOR v_ba IN
    SELECT bt.id AS bt_id, bt.journal_entry_id AS je_id, bt.transaction_date, bt.description, bt.amount
    FROM public.bank_transactions bt
    WHERE bt.business_entity_id = v_pers_id AND bt.description ILIKE '%CITI%'
    ORDER BY bt.transaction_date
  LOOP
    v_amt := ABS(v_ba.amount);
    UPDATE public.journal_lines
       SET account_id = v_owner_contrib_id,
           description = 'Owner contribution to PN: paydown of PN Citi 1247'
     WHERE journal_entry_id = v_ba.je_id AND debit > 0;
    UPDATE public.journal_entries
       SET memo = 'Peter paid PN Citi 1247 from personal bank = owner contribution to PN',
           classified_by='pf4l_citi_pn', classified_at=NOW()
     WHERE id = v_ba.je_id;

    INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
    VALUES (v_agency_id, v_pn_id, v_ba.transaction_date, 'owner_contribution',
            'PN CITI 1247 paydown from Peter personal', 'pf4l_citi_pn', 'classified', 'phase_4l_migration',
            'Owner contribution: Peter paid PN Citi 1247 from personal bank')
    RETURNING id INTO v_je_id;
    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_je_id, v_agency_id, v_new_citi_pn_coa, v_amt, 0, 'Citi 1247 paydown', v_pn_id);
    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_je_id, v_agency_id, v_pn_owner_contrib_id, 0, v_amt, 'Owner contribution from Peter', v_pn_id);
  END LOOP;

  UPDATE public.chart_of_accounts
     SET is_active = false, account_name = account_name || ' [MOVED TO PN pf4l]'
   WHERE id = v_old_citi_pers_coa;
END $pf4l$;

UPDATE public.gl_classification_rules
   SET debit_account_code = 'COA-PN-COGS-PRINT', credit_account_code = 'COA-PN-CC-1247',
       match_source_account = 'COA-PN-CC-1247',
       sub_category_label = 'PN printed products for resale (COGS)',
       rule_name = 'ND4C Houston -> PN Print COGS (Citi 1247)'
 WHERE source = 'pf4k_citi_seed' AND rule_name LIKE 'ND4C Houston%';

UPDATE public.gl_classification_rules
   SET debit_account_code = 'COA-PERSONAL-9985',
       sub_category_label = 'Owner contribution to PN (Citi 1247 paydown)',
       rule_name = 'Bank paying Citi 1247 -> Owner Contribution to PN'
 WHERE source = 'pf4k_citi_seed' AND rule_name = 'Bank paying Citi 1247 -> Internal Transfers';

UPDATE public.gl_classification_rules
   SET match_source_account = 'COA-PN-CC-1247'
 WHERE source = 'pf4k_citi_seed' AND rule_name = 'Citi ONLINE PAYMENT THANK YOU -> Internal Transfers';
