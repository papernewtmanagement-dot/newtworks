DROP TRIGGER lock_chart_of_accounts ON public.chart_of_accounts;

DELETE FROM public.chart_of_accounts WHERE account_code = '9800';

CREATE TRIGGER lock_chart_of_accounts
BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();
