-- =====================================================================
-- Phase 4o: Opening balances at 1/1/2026 (per Alvi) + tithe reconciliation
--
-- Openings booked via new COA-PERSONAL-3000 "Opening Balance Equity":
--   Assets       $24,147.53:  0353 $7,584.52 | 2545 $1,066.43 | 6596 $20 |
--                             6730 $8,478.97 | 6755 $6,997.61
--   Liabilities  $24,833.51:  CC-8847 $536.50 | CC-1006 $21,340 | CC-7435 $2,957.01
--   Net worth at 1/1/26: -$685.98 (negative, due to AMEX life policy carry)
--
-- AMEX 1006 payoff on 1/12/26 = $21,340, source unknown (OBE plug pending January bank statement)
--
-- Tithe reconciliation to Alvi's $23,903.69:
--   +$2,000 aggregate June Church + Actmin (in unshared 06/28-07/27 Discover stmt)
--   +$500 OTHER charitable April — SOURCE UNKNOWN placeholder, OBE plug
-- =====================================================================
DO $pf4o$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id UUID := 'b3333333-3333-3333-3333-333333333333';
  v_obe_id UUID;
  v_0353 UUID; v_2545 UUID; v_6596 UUID; v_6730 UUID; v_6755 UUID;
  v_cc_8847 UUID; v_cc_1006 UUID; v_cc_7435 UUID;
  v_discover_coa UUID; v_tithe_coa UUID;
  v_je_id UUID;
BEGIN
  INSERT INTO public.chart_of_accounts (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES (v_agency_id, v_pers_id, 'COA-PERSONAL-3000', 'Opening Balance Equity', 'equity', 'opening_balance', 'active', true, true)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  SELECT id INTO v_obe_id      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-3000';
  SELECT id INTO v_0353        FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-0353';
  SELECT id INTO v_2545        FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-2545';
  SELECT id INTO v_6596        FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-6596';
  SELECT id INTO v_6730        FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-6730';
  SELECT id INTO v_6755        FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-6755';
  SELECT id INTO v_cc_8847     FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-8847';
  SELECT id INTO v_cc_1006     FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-1006';
  SELECT id INTO v_cc_7435     FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-7435';
  SELECT id INTO v_discover_coa FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-3208';
  SELECT id INTO v_tithe_coa   FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9700';

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-01-01', 'opening_balance', 'Asset opening balances at 1/1/2026 (Alvi spreadsheet)',
          'pf4o_opening_balances', 'classified', 'phase_4o_migration', 'Total $24,147.53')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_0353, 7584.52, 0, 'US Bank Personal Checking 0353', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_2545, 1066.43, 0, 'US Bank Other Income 2545', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_6596, 20.00, 0, 'RBFCU Primary Savings 6596', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_6730, 8478.97, 0, 'US Bank Kids Profit Disc 6730', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_6755, 6997.61, 0, 'US Bank Tithe Tax 6755', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_obe_id, 0, 24147.53, 'OBE credit (asset opens)', v_pers_id);

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-01-01', 'opening_balance', 'Liability opening balances at 1/1/2026 (Alvi spreadsheet)',
          'pf4o_opening_balances', 'classified', 'phase_4o_migration', 'Total $24,833.51. AMEX 1006 is life policy financing paid off by 1/12/26.')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_obe_id, 24833.51, 0, 'OBE debit (liability opens)', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_cc_8847, 0, 536.50, 'US Bank Personal CC 8847', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_cc_1006, 0, 21340.00, 'AMEX Personal 1006 (life policy)', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_cc_7435, 0, 2957.01, 'Capital One Personal 7435', v_pers_id);

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-01-12', 'personal_credit', 'AMEX 1006: Life policy financing paid off',
          'pf4o_amex_payoff', 'classified', 'phase_4o_migration', 'AMEX $21,340 fully paid by 1/12/26. Source unknown (no January bank data). OBE plug pending January statement.')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_cc_1006, 21340.00, 0, 'AMEX paydown', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_obe_id, 0, 21340.00, 'OBE plug for AMEX payoff', v_pers_id);

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-06-25', 'personal_credit', 'DISCOVER: Aggregate June tithe cycle Church + Actmin (statement not obtained)',
          'pf4o_tithe_reconcile', 'classified', 'phase_4o_migration', 'INFERRED per Alvi. June: Church $1,000 + Uganda $1,000. Posts on missing 06/28-07/27 Discover statement.')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_tithe_coa, 2000.00, 0, 'Aggregate June Church + Actmin', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_discover_coa, 0, 2000.00, 'Aggregate June Church + Actmin', v_pers_id);

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-04-15', 'personal_credit', 'CHARITABLE: OTHER $500 (Alvi tracking, SOURCE UNKNOWN)',
          'pf4o_tithe_reconcile', 'classified', 'phase_4o_migration', 'PLACEHOLDER. Alvi tracks $500 OTHER charitable in April 2026, not identifiable from ingested data. OBE plug pending Peter identification of source card + recipient.')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_tithe_coa, 500.00, 0, 'Aggregate April OTHER $500 charitable', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_obe_id, 0, 500.00, 'OBE plug — actual source pending', v_pers_id);
END $pf4o$;
