-- =====================================================================
-- Phase 4q: April $500 Vault donation Venmo pulled from PN Business
-- Checking 3977 (not personal 0353 as intended). Book as intercompany:
--   Personal side: DR Tithe & Charitable, CR "Owed to PaperNewt" (9972)
--   PN side:       DR "Owed by Peter" (IC-004), CR PN Bus Checking 3977
-- When Peter reimburses PN (0353 -> 3977 transfer), intercompany zeros out.
-- =====================================================================

DO $pf4q$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id UUID := 'b3333333-3333-3333-3333-333333333333';
  v_pn_id UUID := 'b1111111-1111-1111-1111-111111111111';
  v_0353_id UUID;
  v_9972_id UUID;
  v_pn_3977_id UUID;
  v_pn_ic_004_id UUID;
  v_je_id UUID;
  v_new_je_id UUID;
BEGIN
  -- Create PN Business Checking 3977 (was missing)
  INSERT INTO public.chart_of_accounts (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES (v_agency_id, v_pn_id, 'COA-PN-3977', 'US Bank Business Checking (3977)', 'asset', 'cash', 'active', true, false)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  SELECT id INTO v_0353_id      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-0353';
  SELECT id INTO v_9972_id      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9972';
  SELECT id INTO v_pn_3977_id   FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-3977';
  SELECT id INTO v_pn_ic_004_id FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-IC-004';

  -- Find the pf4p JE (April OTHER $500 charitable, currently CR 0353)
  SELECT je.id INTO v_je_id FROM public.journal_entries je
   WHERE je.source = 'pf4o_tithe_reconcile' AND je.description ILIKE '%DISCOVER-side charity error corrected%';

  -- Reroute CR from 0353 -> 9972 (Peter now owes PN, not personal cash out)
  UPDATE public.journal_lines
     SET account_id = v_9972_id,
         description = 'Owed back to PaperNewt: PN 3977 funded this personal donation via Venmo (was supposed to pull from 0353)'
   WHERE journal_entry_id = v_je_id
     AND account_id = v_0353_id;

  -- Update JE description/memo
  UPDATE public.journal_entries
     SET description = 'CHARITABLE: April $500 Vault in-kind Venmo (funded by PN 3977, owed back to PN)',
         memo = 'Per Peter: intended to pull from Personal Checking 0353 but Venmo pulled from PN Business Checking 3977 instead. Booked as intercompany: personal recognizes tithe expense with CR to "Owed to PN" (9972). PN side JE records the $500 cash out from 3977 with DR to "Owed by Peter" (IC-004). Will zero out when Peter reimburses PN (0353 -> 3977 transfer).'
   WHERE id = v_je_id;

  -- Create PN-side JE
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pn_id, '2026-04-15', 'intercompany_advance',
          'PN 3977 Venmo advance: personal Vault donation (Peter owes back)',
          'pf4q_pn_500_venmo', 'classified', 'phase_4q_migration',
          'PN Business Checking 3977 paid $500 Venmo to Vault Fostering for a personal charitable donation (should have been Peter personal 0353). Booked as advance to Peter; Peter owes PN $500 back. Will settle when Peter transfers $500 from 0353 to 3977.')
  RETURNING id INTO v_new_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_new_je_id, v_agency_id, v_pn_ic_004_id, 500.00, 0, 'Advance to Peter (personal expense PN funded)', v_pn_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_new_je_id, v_agency_id, v_pn_3977_id, 0, 500.00, 'Venmo outflow to Vault Fostering (Peter personal donation)', v_pn_id);
END $pf4q$;
