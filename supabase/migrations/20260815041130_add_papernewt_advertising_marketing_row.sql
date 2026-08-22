DROP TRIGGER lock_chart_of_accounts ON public.chart_of_accounts;

INSERT INTO public.chart_of_accounts (id, agency_id, account_code, account_name, account_type, business_entity_id, is_active)
SELECT gen_random_uuid(), agency_id, '6400', 'Advertising & Marketing', account_type, 'b1111111-1111-1111-1111-111111111111', true
FROM public.chart_of_accounts WHERE account_code='6400' AND business_entity_id='b2222222-2222-2222-2222-222222222222'
LIMIT 1;

CREATE TRIGGER lock_chart_of_accounts
BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();
