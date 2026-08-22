DROP TRIGGER lock_chart_of_accounts ON public.chart_of_accounts;
DROP TRIGGER lock_account_master_codes ON public.account_master_codes;

-- Delete the redundant empty account I created
DELETE FROM public.chart_of_accounts WHERE id = '739a8d44-788a-49b2-87ec-2c9811ab7a37';
DELETE FROM public.account_master_codes WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND code='4017';

-- Rename the real pre-existing account and parent it under Alliances
UPDATE public.chart_of_accounts
SET account_name = 'Trupanion — Renewal', parent_account_id = 'bbfc387d-fb48-4b97-870e-3b8fd507eef1'
WHERE id = 'fa669c79-ac0d-4ef1-bd8d-f345ff9c5bf8';

UPDATE public.account_master_codes
SET name = 'Trupanion — Renewal', description = 'SF commission — Alliances channel, Trupanion pet insurance renewal'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND code='4131';

CREATE TRIGGER lock_chart_of_accounts
BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();

CREATE TRIGGER lock_account_master_codes
BEFORE INSERT OR UPDATE OR DELETE ON public.account_master_codes
FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();
