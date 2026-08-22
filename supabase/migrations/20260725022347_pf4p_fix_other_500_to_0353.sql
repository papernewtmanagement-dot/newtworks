-- =====================================================================
-- Phase 4p: Fix April OTHER $500 charitable
-- Peter identified: in-kind goods to Vault, paid via Venmo from Personal Checking 0353
-- Update pf4o placeholder JE: CR side from OBE -> Personal Checking 0353
-- Note: actual Venmo outflow not found in ingested 0353 April data; likely in an
-- April 0353 statement gap. When full April statement obtained, this JE will
-- match the bank line.
-- =====================================================================

DO $pf4p$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_obe_id UUID;
  v_0353 UUID;
  v_je_id UUID;
BEGIN
  SELECT id INTO v_obe_id FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-3000';
  SELECT id INTO v_0353   FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-0353';

  SELECT id INTO v_je_id FROM public.journal_entries
   WHERE source = 'pf4o_tithe_reconcile' AND description ILIKE '%OTHER $500%';

  -- Update the CR line from OBE to 0353
  UPDATE public.journal_lines
     SET account_id = v_0353,
         description = 'Venmo to Vault Fostering (in-kind goods) — actual bank line not in ingested data'
   WHERE journal_entry_id = v_je_id
     AND account_id = v_obe_id;

  -- Update JE memo + description to reflect actual source
  UPDATE public.journal_entries
     SET description = 'DISCOVER-side charity error corrected: April in-kind Vault donation via Venmo from Personal Checking 0353',
         memo = 'Per Peter: April OTHER $500 = in-kind goods to Vault Fostering paid via Venmo from Personal Checking 0353. Actual bank transaction not found in ingested 0353 April data (likely in a statement gap around mid-April between 4/16 and 4/21). This JE stands as the accounting record; will reconcile to bank line when full April 0353 statement obtained.'
   WHERE id = v_je_id;
END $pf4p$;
