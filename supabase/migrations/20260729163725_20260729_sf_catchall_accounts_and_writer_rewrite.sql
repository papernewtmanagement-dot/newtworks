-- Create catchall SF sub-accounts under State Farm income parent and Administration expense parent
DO $$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_entity_id uuid := 'b2222222-2222-2222-2222-222222222222';
  v_sf_parent uuid;
  v_admin_parent uuid;
BEGIN
  SELECT id INTO v_sf_parent FROM public.chart_of_accounts
    WHERE account_code = 'COA-018' AND agency_id = v_agency_id;
  SELECT id INTO v_admin_parent FROM public.chart_of_accounts
    WHERE account_code = 'COA-019' AND agency_id = v_agency_id;

  IF NOT EXISTS (SELECT 1 FROM public.chart_of_accounts
                 WHERE account_code = 'COA-SUB-SF-UNCL-INC' AND agency_id = v_agency_id) THEN
    INSERT INTO public.chart_of_accounts (
      agency_id, business_entity_id, account_code, account_name, account_type, parent_account_id
    ) VALUES (
      v_agency_id, v_entity_id, 'COA-SUB-SF-UNCL-INC',
      '09 - SF Unclassified Income', 'income', v_sf_parent
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.chart_of_accounts
                 WHERE account_code = 'COA-SUB-SF-UNCL-DED' AND agency_id = v_agency_id) THEN
    INSERT INTO public.chart_of_accounts (
      agency_id, business_entity_id, account_code, account_name, account_type, parent_account_id
    ) VALUES (
      v_agency_id, v_entity_id, 'COA-SUB-SF-UNCL-DED',
      '99 - SF Unclassified Deduction', 'expense', v_admin_parent
    );
  END IF;
END $$;
