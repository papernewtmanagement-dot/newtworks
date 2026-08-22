INSERT INTO public.chart_of_accounts (
  agency_id, business_entity_id, account_code, account_name,
  account_type, account_subtype, is_active, is_system
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'b1111111-1111-1111-1111-111111111111',
  '6110', 'Employee Benefits', 'expense', 'benefits', true, false
)
ON CONFLICT DO NOTHING;
