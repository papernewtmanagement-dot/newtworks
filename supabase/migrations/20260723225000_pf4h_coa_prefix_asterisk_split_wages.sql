-- =====================================================================
-- Phase 4h: COA- prefix on all my accounts + *Unclassified + split W2 wages by payer
-- =====================================================================
DO $pf4h$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id   UUID := 'b3333333-3333-3333-3333-333333333333';
  v_papernewt_wages_id UUID;
  v_gloelle_wages_id   UUID;
BEGIN
  -- 1. Add COA- prefix to every account I created that's missing it
  UPDATE public.chart_of_accounts
     SET account_code = 'COA-' || account_code
   WHERE agency_id = v_agency_id
     AND chart_namespace = 'active'
     AND (account_code LIKE 'PERSONAL-%'
          OR account_code LIKE 'ERIOSTO-%'
          OR (account_code LIKE 'PN-%' AND account_code NOT LIKE 'COA-%'));

  -- 2. Rename both Unclassified buckets with asterisk prefix
  UPDATE public.chart_of_accounts
     SET account_name = '*Unclassified'
   WHERE agency_id = v_agency_id
     AND chart_namespace = 'active'
     AND account_code IN ('COA-PERSONAL-8999','COA-PERSONAL-9999');

  -- 3. Split Personal Wages by payer
  UPDATE public.chart_of_accounts
     SET account_code = 'COA-PERSONAL-8110',
         account_name = 'PaperNewt LLC W2'
   WHERE agency_id = v_agency_id
     AND chart_namespace = 'active'
     AND account_code = 'COA-PERSONAL-8100';

  SELECT id INTO v_papernewt_wages_id FROM public.chart_of_accounts
    WHERE agency_id = v_agency_id AND chart_namespace = 'active' AND account_code = 'COA-PERSONAL-8110';

  INSERT INTO public.chart_of_accounts
    (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES
    (v_agency_id, v_pers_id, 'COA-PERSONAL-8120', 'Gloelle LLC W2', 'income', 'wages', 'active', true, false)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  SELECT id INTO v_gloelle_wages_id FROM public.chart_of_accounts
    WHERE agency_id = v_agency_id AND chart_namespace = 'active' AND account_code = 'COA-PERSONAL-8120';

  -- 4. Move Marie's Gloelle deposits from PaperNewt wages COA to Gloelle wages COA
  UPDATE public.journal_lines
     SET account_id = v_gloelle_wages_id
   WHERE journal_entry_id IN (
     SELECT id FROM public.journal_entries
      WHERE source = 'pf4_personal_backfill'
        AND business_entity_id = v_pers_id
        AND description ILIKE '%GLOELE LLC PAYROLL%'
   )
     AND account_id = v_papernewt_wages_id;
END $pf4h$;
