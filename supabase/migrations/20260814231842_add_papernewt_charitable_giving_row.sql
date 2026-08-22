DROP TRIGGER lock_chart_of_accounts ON public.chart_of_accounts;

INSERT INTO public.chart_of_accounts (id, agency_id, account_code, account_name, account_type, business_entity_id, is_active)
SELECT gen_random_uuid(), agency_id, '9700', 'Tithe & Charitable', account_type, 'b1111111-1111-1111-1111-111111111111', true
FROM public.chart_of_accounts WHERE account_code='9700' AND business_entity_id='b3333333-3333-3333-3333-333333333333'
LIMIT 1;

CREATE TRIGGER lock_chart_of_accounts
BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();
