INSERT INTO public.accounts (
  id, agency_id, business_entity_id, account_kind, account_name, institution,
  account_type, account_number_last4, chart_account_id, is_active, drive_folder_id
)
VALUES (
  gen_random_uuid(),
  '126794dd-25ff-47d2-a436-724499733365',
  'b3333333-3333-3333-3333-333333333333',
  'bank',
  'Fidelity HSA',
  'Fidelity',
  'hsa',
  '9615',
  '826e7b0f-aaad-4821-b508-578dd1acbd53',
  true,
  '1PYZEt785PVbcH4HNoFpAtk1SNFGpQrSa'
);
