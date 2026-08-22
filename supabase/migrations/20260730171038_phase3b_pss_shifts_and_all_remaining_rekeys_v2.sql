-- Phase 3B v2: Complete Phase 3 rekey work
-- Change vs v1: Free blocked target codes by rekeying blockers to DELETED- prefix
-- instead of DELETE (avoids parent_account_id FK cascade issue).

-- 1. Add master codes for PSS US Bank operational accounts (if not already present)
INSERT INTO public.account_master_codes (agency_id, code, name, account_type, account_subtype, code_kind)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', '1011', 'PSS — US Bank Expenses (4335)', 'asset', 'bank', 'entity_specific'),
  ('126794dd-25ff-47d2-a436-724499733365', '1012', 'PSS — US Bank Income', 'asset', 'bank', 'entity_specific')
ON CONFLICT (agency_id, code) DO NOTHING;

-- 2. Free target codes by moving zero-activity blockers to DELETED- prefix (they stay
--    inactive; Phase 6 does the actual DELETE after parent_account_id references are nulled)
UPDATE public.chart_of_accounts
   SET account_code = 'DELETED-' || account_code
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND is_active = false
   AND account_code IN ('1500','2110','2120')
   AND account_name IN ('Fixed Assets','Business Credit Card — Chase','Business Credit Card — Other');

-- 3. Rekey helper
CREATE OR REPLACE FUNCTION public._phase3_rekey_account(
  p_agency uuid,
  p_old_code text,
  p_new_code text
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.chart_of_accounts SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.gl_classification_rules SET debit_account_code = p_new_code
   WHERE agency_id = p_agency AND debit_account_code = p_old_code;
  UPDATE public.gl_classification_rules SET credit_account_code = p_new_code
   WHERE agency_id = p_agency AND credit_account_code = p_old_code;
  UPDATE public.statement_balances SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.opening_balances SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.documents SET source_account_code = p_new_code
   WHERE agency_id = p_agency AND source_account_code = p_old_code;
  UPDATE public.gmail_label_classification_map SET source_account_code = p_new_code
   WHERE agency_id = p_agency AND source_account_code = p_old_code;
  UPDATE public.envelope_budget_targets SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.prior_year_pl_account_map SET newtworks_account_code = p_new_code
   WHERE agency_id = p_agency AND newtworks_account_code = p_old_code;
END;
$$;

-- 4. PSS 4-digit shift chain via temp prefix
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1020', 'REKEY-1015');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1030', 'REKEY-1020');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1040', 'REKEY-1030');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1510', 'REKEY-1500');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1515', 'REKEY-1505');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1520', 'REKEY-1510');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1525', 'REKEY-1515');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1530', 'REKEY-1520');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1535', 'REKEY-1525');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1540', 'REKEY-1530');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', '1545', 'REKEY-1535');

SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1015', '1015');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1020', '1020');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1030', '1030');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1500', '1500');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1505', '1505');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1510', '1510');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1515', '1515');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1520', '1520');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1525', '1525');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1530', '1530');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'REKEY-1535', '1535');

-- 5. PSS COA-### active-account rekeys
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-001', '1040');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-006', '1011');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-007', '1012');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-010', '2115');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-011', '2110');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-028', '2114');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-036', '2113');

-- 6. Reactivate + rekey PSS suspense rows
UPDATE public.chart_of_accounts SET is_active = true
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('COA-UNCL-PSS','COA-UNCL-PSS-INC','COA-SUSP');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-UNCL-PSS', '0003');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-UNCL-PSS-INC', '0002');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-SUSP', '0005');

-- 7. PaperNewt rekeys (excluding Phase 4 items)
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-IC-002', '1901');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-3977', '1050');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-IC-004', '1910');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-EQUITY-CONTRIB', '3070');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-COGS-PRINT', '5100');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-HOME-OFFICE-SECURITY', '6280');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-MEALS', '6860');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-TRAVEL', '6850');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-UNCL-PAPERNEWT', '0003');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-REVENUE-LIGHTSHINE', '4310');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-REVENUE-PRINT', '4300');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-IC-003', '2910');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-CC-1247', '2140');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-LOAN-SBA-EIDL', '2511');

-- 8. Eriosto rekeys
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-ERIOSTO-1500', '1901');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-UNCL-ERIOSTO', '0003');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-ERIOSTO-4100', '4400');

-- 9. Steward rekey
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-UNCL-STEWARD', '0003');

DROP FUNCTION IF EXISTS public._phase3_rekey_account(uuid, text, text);
