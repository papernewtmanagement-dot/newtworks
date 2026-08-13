ALTER TABLE public.accounts DROP CONSTRAINT accounts_account_kind_check;
ALTER TABLE public.accounts ADD CONSTRAINT accounts_account_kind_check
  CHECK (account_kind = ANY (ARRAY['bank'::text, 'credit'::text, 'investment'::text]));

INSERT INTO public.accounts (id, agency_id, business_entity_id, account_kind, account_name, institution, account_type, chart_account_id, is_active, is_primary)
VALUES (
  extensions.uuid_generate_v4(),
  '126794dd-25ff-47d2-a436-724499733365',
  'b2222222-2222-2222-2222-222222222222',
  'investment',
  'CDs & Short-Term Investments',
  'US Bank',
  'certificate_of_deposit',
  'ccc41801-41cd-4677-9c39-076cfa989a7c',
  true,
  false
);
