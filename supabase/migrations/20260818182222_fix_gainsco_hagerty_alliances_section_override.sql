DROP TRIGGER lock_chart_of_accounts ON chart_of_accounts;

UPDATE chart_of_accounts
SET section_label_override = 'Alliances - SF Comp'
WHERE account_code IN ('4019','4026')
  AND business_entity_id = 'b2222222-2222-2222-2222-222222222222'::uuid;

CREATE TRIGGER lock_chart_of_accounts BEFORE INSERT OR DELETE OR UPDATE ON public.chart_of_accounts FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();
