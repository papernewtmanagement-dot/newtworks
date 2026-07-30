-- Phase 4a: Seed destination chart_of_accounts rows for the reclassification work.
-- No new master codes needed — all destination codes already exist in account_master_codes.
-- Adds 15 income + 7 expense + 1 asset rows on PSS, plus 1 expense row on PaperNewt.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pss uuid := 'b2222222-2222-2222-2222-222222222222';
  v_pn  uuid := 'b1111111-1111-1111-1111-111111111111';
  v_code text;
  v_name text;
  v_type text;
  v_subtype text;
  v_rows record;
BEGIN
  -- PSS income destinations (from account_master_codes, code_kind='shared_concept')
  FOR v_rows IN
    SELECT code, name, account_type, account_subtype
    FROM public.account_master_codes
    WHERE agency_id = v_agency
      AND code IN ('4010','4020','4021','4022','4023','4025','4100','4101',
                   '4110','4111','4120','4121','4131','4140','4200')
  LOOP
    INSERT INTO public.chart_of_accounts
      (id, agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, is_active)
    VALUES
      (gen_random_uuid(), v_agency, v_pss, v_rows.code, v_rows.name, v_rows.account_type, v_rows.account_subtype, true)
    ON CONFLICT DO NOTHING;
  END LOOP;

  -- PSS expense destinations (6160 Employee Relations & Meals, 6180 Recruitment,
  -- 6270 Home Office Reimb, 6280 Security, 6400 Advertising & Marketing,
  -- 6941 Interest Expense) + PSS asset destination (0001 Unclassified Asset)
  FOR v_rows IN
    SELECT code, name, account_type, account_subtype
    FROM public.account_master_codes
    WHERE agency_id = v_agency
      AND code IN ('0001','6160','6180','6270','6280','6400','6941')
  LOOP
    INSERT INTO public.chart_of_accounts
      (id, agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, is_active)
    VALUES
      (gen_random_uuid(), v_agency, v_pss, v_rows.code, v_rows.name, v_rows.account_type, v_rows.account_subtype, true)
    ON CONFLICT DO NOTHING;
  END LOOP;

  -- PaperNewt expense destination: 6020 Owner W-2 Wages (S-Corp)
  INSERT INTO public.chart_of_accounts
    (id, agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, is_active)
  SELECT gen_random_uuid(), v_agency, v_pn, code, name, account_type, account_subtype, true
  FROM public.account_master_codes
  WHERE agency_id = v_agency AND code = '6020'
  ON CONFLICT DO NOTHING;
END $$;
