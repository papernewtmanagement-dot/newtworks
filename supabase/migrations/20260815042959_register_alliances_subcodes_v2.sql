DROP TRIGGER lock_account_master_codes ON public.account_master_codes;
DROP TRIGGER lock_chart_of_accounts ON public.chart_of_accounts;

INSERT INTO public.account_master_codes (agency_id, code, name, account_type, account_subtype, code_kind, description)
VALUES
('126794dd-25ff-47d2-a436-724499733365','4016','Trupanion — New','income','commission','shared_concept','SF commission — Alliances channel, Trupanion pet insurance new business'),
('126794dd-25ff-47d2-a436-724499733365','4017','Trupanion — Renewal','income','commission','shared_concept','SF commission — Alliances channel, Trupanion pet insurance renewal'),
('126794dd-25ff-47d2-a436-724499733365','4018','US Bank','income','commission','shared_concept','SF commission — Alliances channel, US Bank'),
('126794dd-25ff-47d2-a436-724499733365','4019','Gainsco','income','commission','shared_concept','SF commission — Alliances channel, Gainsco'),
('126794dd-25ff-47d2-a436-724499733365','4026','Hagerty','income','commission','shared_concept','SF commission — Alliances channel, Hagerty');

INSERT INTO public.chart_of_accounts (id, agency_id, account_code, account_name, account_type, business_entity_id, parent_account_id, is_active)
SELECT gen_random_uuid(), agency_id, '4016', 'Trupanion — New', 'income', 'b2222222-2222-2222-2222-222222222222', id, true
FROM public.chart_of_accounts WHERE account_code='4010' AND business_entity_id='b2222222-2222-2222-2222-222222222222';

INSERT INTO public.chart_of_accounts (id, agency_id, account_code, account_name, account_type, business_entity_id, parent_account_id, is_active)
SELECT gen_random_uuid(), agency_id, '4017', 'Trupanion — Renewal', 'income', 'b2222222-2222-2222-2222-222222222222', id, true
FROM public.chart_of_accounts WHERE account_code='4010' AND business_entity_id='b2222222-2222-2222-2222-222222222222';

INSERT INTO public.chart_of_accounts (id, agency_id, account_code, account_name, account_type, business_entity_id, parent_account_id, is_active)
SELECT gen_random_uuid(), agency_id, '4018', 'US Bank', 'income', 'b2222222-2222-2222-2222-222222222222', id, true
FROM public.chart_of_accounts WHERE account_code='4010' AND business_entity_id='b2222222-2222-2222-2222-222222222222';

INSERT INTO public.chart_of_accounts (id, agency_id, account_code, account_name, account_type, business_entity_id, parent_account_id, is_active)
SELECT gen_random_uuid(), agency_id, '4019', 'Gainsco', 'income', 'b2222222-2222-2222-2222-222222222222', id, true
FROM public.chart_of_accounts WHERE account_code='4010' AND business_entity_id='b2222222-2222-2222-2222-222222222222';

INSERT INTO public.chart_of_accounts (id, agency_id, account_code, account_name, account_type, business_entity_id, parent_account_id, is_active)
SELECT gen_random_uuid(), agency_id, '4026', 'Hagerty', 'income', 'b2222222-2222-2222-2222-222222222222', id, true
FROM public.chart_of_accounts WHERE account_code='4010' AND business_entity_id='b2222222-2222-2222-2222-222222222222';

CREATE TRIGGER lock_chart_of_accounts
BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();

CREATE TRIGGER lock_account_master_codes
BEFORE INSERT OR UPDATE OR DELETE ON public.account_master_codes
FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();
