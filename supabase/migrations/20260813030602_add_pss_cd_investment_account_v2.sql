-- Unlock, add PSS CD/short-term investment asset account (master code + chart account), relock
DROP TRIGGER IF EXISTS lock_chart_of_accounts ON chart_of_accounts;
DROP TRIGGER IF EXISTS lock_account_master_codes ON account_master_codes;

INSERT INTO public.account_master_codes (agency_id, code, name, account_type, account_subtype, code_kind, description)
VALUES ('126794dd-25ff-47d2-a436-724499733365', '1016', 'PSS — CDs & Short-Term Investments', 'asset', 'investment', 'entity_specific', 'Holds principal while money is parked in a CD or other short-term interest-bearing instrument. Buy = debit here / credit source bank. Mature/close = debit destination bank / credit here for principal (interest portion routes to 8200 Interest & Investment Income). No per-CD tracking - one pooled balance.');

INSERT INTO public.chart_of_accounts (agency_id, account_code, account_name, account_type, account_subtype, parent_account_id, is_active, is_system, business_entity_id)
VALUES ('126794dd-25ff-47d2-a436-724499733365', '1016', 'PSS — CDs & Short-Term Investments', 'asset', 'investment', NULL, true, false, 'b2222222-2222-2222-2222-222222222222');

CREATE TRIGGER lock_chart_of_accounts
BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();

CREATE TRIGGER lock_account_master_codes
BEFORE INSERT OR UPDATE OR DELETE ON public.account_master_codes
FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();

