DO $pf4n$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id UUID := 'b3333333-3333-3333-3333-333333333333';
  v_discover_coa_id UUID;
  v_tithe_coa_id UUID;
  v_je_id UUID;
BEGIN
  SELECT id INTO v_discover_coa_id FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-3208';
  SELECT id INTO v_tithe_coa_id    FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9700';

  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-01-31', 'personal_credit',
          'DISCOVER: Aggregate January 2026 tithe (statement not obtained; opening balance plug)',
          'pf4n_discover_opening', 'classified', 'phase_4n_migration',
          'INFERRED Jan 2026 tithe: Doc 8 (Feb 28-Mar 27 activity) opens with $3,566.38 balance = prior statement (Jan 28-Feb 27) closing. Monthly pattern is exactly $3,566.38 (4 recipients: Reasonable Faith, Vault Fostering, Christ Community, Actmin). Booking as aggregate Jan tithe to roll forward Discover balance to match statements.')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_tithe_coa_id, 3566.38, 0, 'Aggregate Jan 2026 tithe (opening plug)', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_discover_coa_id, 0, 3566.38, 'Aggregate Jan 2026 tithe (opening plug)', v_pers_id);
END $pf4n$;
