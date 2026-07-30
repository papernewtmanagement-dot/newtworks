-- =====================================================================
-- Phase 3B: Complete Phase 3 rekey work
--
-- Scope:
--   1. Add master codes 1011, 1012 for PSS US Bank Expenses/Income
--   2. Free target codes by moving zero-activity blockers to DELETED-
--      prefix (Phase 6 will drop them after parent_account_id chain is
--      nulled — chart_of_accounts has a self-referencing FK that blocks
--      naive DELETE of header rows)
--   3. PSS 4-digit shift chain (1020->1015, 1030->1020, 1040->1030,
--      1510->1500, 1515->1505, 1520->1510, 1525->1515, 1530->1520,
--      1535->1525, 1540->1530, 1545->1535) using REKEY- temp prefix
--      to avoid transient collisions
--   4. PSS COA-### active-account rekeys (banks + CCs):
--      COA-001->1040, COA-006->1011, COA-007->1012, COA-010->2115,
--      COA-011->2110, COA-028->2114, COA-036->2113
--   5. Reactivate + rekey PSS suspense rows to master 0002/0003/0005
--      (Migration A over-eagerly deactivated these; app needs them for
--      operational suspense routing)
--   6. PaperNewt COA-PN-* / COA-IC-* rekeys (skip PN-001 + PN-002 which
--      are Phase 4 material — they have activity that needs journal-
--      line-level reclassification)
--   7. Eriosto + Steward rekeys
--
-- Every rekey fans out to the 8 downstream tables via helper function.
-- Author: Claude (Phase 3 CoA overhaul)
-- Date:   2026-07-30
-- =====================================================================

INSERT INTO public.account_master_codes (agency_id, code, name, account_type, account_subtype, code_kind)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', '1011', 'PSS — US Bank Expenses (4335)', 'asset', 'bank', 'entity_specific'),
  ('126794dd-25ff-47d2-a436-724499733365', '1012', 'PSS — US Bank Income', 'asset', 'bank', 'entity_specific')
ON CONFLICT (agency_id, code) DO NOTHING;

UPDATE public.chart_of_accounts
   SET account_code = 'DELETED-' || account_code
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND is_active = false
   AND account_code IN ('1500','2110','2120')
   AND account_name IN ('Fixed Assets','Business Credit Card — Chase','Business Credit Card — Other');

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

-- PSS 4-digit shift chain (source -> temp)
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

-- PSS 4-digit shift chain (temp -> final)
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

-- PSS COA-### active-account rekeys
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-001', '1040');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-006', '1011');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-007', '1012');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-010', '2115');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-011', '2110');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-028', '2114');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-036', '2113');

-- Reactivate + rekey PSS suspense rows
UPDATE public.chart_of_accounts SET is_active = true
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('COA-UNCL-PSS','COA-UNCL-PSS-INC','COA-SUSP');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-UNCL-PSS', '0003');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-UNCL-PSS-INC', '0002');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-SUSP', '0005');

-- PaperNewt rekeys (excluding Phase 4 items)
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

-- Eriosto rekeys
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-ERIOSTO-1500', '1901');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-UNCL-ERIOSTO', '0003');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-ERIOSTO-4100', '4400');

-- Steward rekey
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-UNCL-STEWARD', '0003');

DROP FUNCTION IF EXISTS public._phase3_rekey_account(uuid, text, text);
