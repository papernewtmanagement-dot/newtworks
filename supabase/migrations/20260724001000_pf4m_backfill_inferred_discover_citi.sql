-- =====================================================================
-- Phase 4m: Backfill inferred activity from balance math
--
-- Discover 04/28-05/27 missing statement:
--   Payment: $5,571.79 (bank-verified from 5/8 bank withdrawal)
--   Charges: $3,566.38 aggregate (exact per balance math: Doc 2 closing
--     $5,571.79 - payment $5,571.79 + charges = Doc 6 opening $3,566.38)
--   Composition inferred as typical 4-recipient tithe pattern; booked
--   as single aggregate JE dated 5/15/2026
--
-- Citi 1247 pre-Feb plug:
--   $308.09 aggregate PN Print COGS charge dated 2/1/2026
--   Represents pre-window charges implied by bank 3/19 payment ($204.45)
--   and CC 5/2 payment ($103.64) without matching recorded charges
-- =====================================================================
DO $pf4m$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id UUID := 'b3333333-3333-3333-3333-333333333333';
  v_pn_id UUID := 'b1111111-1111-1111-1111-111111111111';
  v_discover_coa_id UUID;
  v_citi_pn_coa_id UUID;
  v_tithe_coa_id UUID;
  v_transfers_coa_id UUID;
  v_pn_cogs_id UUID;
  v_je_id UUID;
BEGIN
  SELECT id INTO v_discover_coa_id     FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-3208';
  SELECT id INTO v_citi_pn_coa_id      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-CC-1247';
  SELECT id INTO v_tithe_coa_id        FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9700';
  SELECT id INTO v_transfers_coa_id    FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9990';
  SELECT id INTO v_pn_cogs_id          FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-COGS-PRINT';

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-05-15', 'personal_credit', 'DISCOVER: Aggregate tithe charges 04/28-05/27 (statement not obtained)',
          'pf4m_discover_inferred', 'classified', 'phase_4m_migration',
          'INFERRED from balance math. Composition likely 4 typical tithe recipients; true up when statement obtained.')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_tithe_coa_id, 3566.38, 0, 'Aggregate tithe charges 04/28-05/27', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_discover_coa_id, 0, 3566.38, 'Aggregate tithe charges 04/28-05/27', v_pers_id);

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-05-06', 'personal_credit', 'DISCOVER: INTERNET PAYMENT - THANK YOU (04/28-05/27 statement payoff)',
          'pf4m_discover_inferred', 'classified', 'phase_4m_migration', 'Bank-verified payment; CC-side date inferred at 5/6')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_discover_coa_id, 5571.79, 0, 'Payment received', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_transfers_coa_id, 0, 5571.79, 'Payment received', v_pers_id);

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pn_id, '2026-02-01', 'business_credit', 'PN CITI 1247: Pre-February 2026 aggregate charges (statement not obtained)',
          'pf4m_citi_pn_plug', 'classified', 'phase_4m_migration', 'INFERRED. Bank 3/19 $204.45 + CC 5/2 $103.64 = $308.09 pre-window charges.')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_pn_cogs_id, 308.09, 0, 'Aggregate pre-Feb 2026 PN Citi charges', v_pn_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id) VALUES (v_je_id, v_agency_id, v_citi_pn_coa_id, 0, 308.09, 'Aggregate pre-Feb 2026 PN Citi charges', v_pn_id);
END $pf4m$;
