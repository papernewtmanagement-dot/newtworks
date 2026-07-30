-- =====================================================================
-- Phase 3A: Align Personal entity chart_of_accounts to master codes,
-- and deactivate zero-activity rows across all entities that no longer
-- fit the new numbering plan.
--
-- Author: Claude (Phase 3 CoA overhaul)
-- Date:   2026-07-30
--
-- Scope of this migration:
--   1. Personal (45 rows): strip COA-PERSONAL- prefix, map to master
--      codes 1070-1076 (banks), 1400 (HSA), 1911 (personal-paid biz exp),
--      2170-2173 (personal CCs), 2902-2903 (intercompany DUE TO),
--      3020 / 3070 / 3090 / 3900 (equity), 8110-8600 (personal income),
--      9100-9910 + 0004 (personal expenses).
--   2. Deactivate zero-activity rows (no journal lines) that either
--      violate cash basis (accrual accounts), are pure headers, are
--      legacy budget-category rows destined for Phase 7 extraction, are
--      unauthorized subclass rows (staff wage splits, payroll tax splits,
--      SaaS subclasses without activity, etc.), or are legacy generic
--      buckets that never had activity.
--   3. Deactivate Book of Business — Flood (COA-027, zero activity) —
--      not a GAAP intangible.
--
-- NOT in scope (deferred to later migrations):
--   - PSS 4-digit code SHIFTS (Batch B: 1020->1015, 1030->1020, etc.)
--   - PSS COA-### active-account rekeys (Batch B: COA-006, 007, 010,
--     011, 028, 036).
--   - PSS COA-SUB-### merges into 6xxx (Phase 4: reclassification
--     utility, ~90 rows).
--   - PaperNewt COA-PN-001 6005 Payroll Costs (38 lines) and
--     COA-PN-002 Payroll Cash (74 lines) (Phase 4 reclassification).
--
-- Every account_code change fans out to 8 downstream tables:
--   gl_classification_rules (debit_account_code, credit_account_code),
--   statement_balances.account_code,
--   opening_balances.account_code,
--   documents.source_account_code,
--   gmail_label_classification_map.source_account_code,
--   envelope_budget_targets.account_code,
--   prior_year_pl_account_map.newtworks_account_code.
--
-- Everything runs in a single transaction. If any statement fails, the
-- entire migration rolls back.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helper: rekey_account(agency, old_code, new_code, [new_name])
--   - Renames a chart_of_accounts row (by agency + old_code) to new_code
--   - Updates all 8 downstream tables that reference account_code as text
--   - Optionally updates the account_name on chart_of_accounts as well
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._phase3_rekey_account(
  p_agency uuid,
  p_old_code text,
  p_new_code text,
  p_new_name text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- chart_of_accounts primary rekey
  UPDATE public.chart_of_accounts
     SET account_code = p_new_code,
         account_name = COALESCE(p_new_name, account_name)
   WHERE agency_id = p_agency
     AND account_code = p_old_code;

  -- 8-table fan-out (each is a no-op if no rows match)
  UPDATE public.gl_classification_rules
     SET debit_account_code = p_new_code
   WHERE agency_id = p_agency AND debit_account_code = p_old_code;

  UPDATE public.gl_classification_rules
     SET credit_account_code = p_new_code
   WHERE agency_id = p_agency AND credit_account_code = p_old_code;

  UPDATE public.statement_balances
     SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;

  UPDATE public.opening_balances
     SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;

  UPDATE public.documents
     SET source_account_code = p_new_code
   WHERE agency_id = p_agency AND source_account_code = p_old_code;

  UPDATE public.gmail_label_classification_map
     SET source_account_code = p_new_code
   WHERE agency_id = p_agency AND source_account_code = p_old_code;

  UPDATE public.envelope_budget_targets
     SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;

  UPDATE public.prior_year_pl_account_map
     SET newtworks_account_code = p_new_code
   WHERE agency_id = p_agency AND newtworks_account_code = p_old_code;
END;
$$;

-- =====================================================================
-- SECTION 1: Personal (45 rows) — strip COA-PERSONAL- prefix
-- =====================================================================

-- Banks & HSA (assets)
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-0353', '1070');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-2545', '1071');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-6730', '1072');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-6755', '1073');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-6608', '1075');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-6596', '1076');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9615', '1400');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9971', '1911');

-- Equity
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-3000', '3900');
-- On Personal books, receipt of distribution from PaperNewt is the mirror of
-- PaperNewt's 3050 S-Corp Distributions (equity flow between owner and S-Corp).
-- Contribution to PaperNewt is the mirror of 3070 owner contributions.
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9980', '3050');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9985', '3070');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9990', '3090');

-- Liabilities
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9970', '2903');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9972', '2902');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-CC-1006', '2170');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-CC-3208', '2171');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-CC-7435', '2172');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-CC-8847', '2173');

-- Income (personal 8xxx)
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8110', '8110');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8120', '8120');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8200', '8200');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8300', '8300');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8400', '8400');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8500', '8500');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-8600', '8600');

-- Expenses (personal 9xxx)
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9100', '9100');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9110', '9110');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9120', '9120');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9200', '9200');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9210', '9210');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9250', '9250');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9300', '9300');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9310', '9310');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9320', '9320');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9400', '9400');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9500', '9500');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9600', '9600');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9610', '9610');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9620', '9620');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9700', '9700');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9800', '9800');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9820', '9820');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9900', '9900');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9910', '9910');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-PERSONAL-9999', '0004');

-- =====================================================================
-- SECTION 2: Zero-activity deactivations
-- All rows verified as having zero journal_lines rows referencing them.
-- =====================================================================

-- PSS accrual accounts (cash-basis-principle deactivate)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('1100','1110','1120','1200','1210','1220','1230','2010','2020','2030','2070','COA-030')
   AND is_active = true;

-- PSS header rows (Phase 6 will DROP; Phase 3 flips is_active)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('1000','1500','2000','2100','2500','3000','4900','6000','6700')
   AND account_subtype = 'header'
   AND is_active = true;

-- PSS legacy generic credit-card bucket rows (0 activity; specific cards live at 2110-2120 in master)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('2110','2120')
   AND account_name IN ('Business Credit Card — Chase','Business Credit Card — Other')
   AND is_active = true;

-- PSS never-authorized staff wage subclass rows (legacy import artifact per handoff)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6011','6012','6013')
   AND is_active = true;

-- PSS payroll tax subclass rows (0 activity; master consolidates into 6030)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6031','6032','6033','6034')
   AND is_active = true;

-- PSS Staff Commissions / Bonuses (0 activity; master consolidates into 6010)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6040','6050')
   AND is_active = true;

-- PSS Workers Comp (0 activity; fold into 6620 Business Insurance conceptually — will migrate any future entries)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code = '6130'
   AND is_active = true;

-- PSS facilities sub-rows (0 activity; fold into 6220/6240 in master)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code = '6230'
   AND is_active = true;

-- PSS SaaS subclass rows w/o activity (0 activity; fold into 6310)
-- 6311 (Claude.ai, 5 lines) and 6315 (Other Software, 15 lines) STAY active - Phase 4 reclassify
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6312','6313','6314')
   AND is_active = true;

-- PSS IT Support (0 activity; fold into 6330)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code = '6340'
   AND is_active = true;

-- PSS marketing sub-rows w/o activity (fold into 6400/6440 in master)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6420','6430','6440','6450','6460')
   AND is_active = true;

-- PSS Payroll Processing Fees (0 activity; fold into 6510)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code = '6540'
   AND is_active = true;

-- PSS BOP (0 activity; fold into 6620)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code = '6630'
   AND is_active = true;

-- PSS Licensing Reimbursement + Training (0 activity; fold into 6710/6720)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6715','6730')
   AND is_active = true;

-- PSS vehicle sub-rows (0 activity; fold into 6810 in master)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6820','6830','6840')
   AND is_active = true;

-- PSS supplies sub-rows (0 activity; fold into 6910 in master)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6920','6930')
   AND is_active = true;

-- PSS interest sub-rows (0 activity; master consolidates 6941/6942 into 6941 Interest Expense)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('6941','6942')
   AND is_active = true;

-- PSS other-non-operating rows (0 activity; fold into 6950 Misc)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('8020','8040')
   AND is_active = true;

-- PSS TRB accounts (0 activity; presumably closed/legacy)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('COA-002','COA-003','COA-004','COA-005')
   AND is_active = true;

-- PSS legacy stub rows w/ 0 activity (Uncategorized Asset, old OBE, old carryforward plug, 4025 NFIP stub,
-- Gainsco stub, State Farm stub, old Retained Earnings stub, Spark stub, old SF Checking stub, Alliances / IPS / External stubs,
-- Suspense stub — all superseded by master codes)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('COA-008','COA-015','COA-016','COA-017','COA-018','COA-024','COA-026','COA-029','COA-033','COA-034','COA-035','COA-SUSP','COA-UNCL-PSS','COA-UNCL-PSS-INC')
   AND is_active = true;

-- Book of Business - Flood (0 activity; not a GAAP intangible per handoff)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code = 'COA-027'
   AND is_active = true;

-- Legacy budget-category rows on PSS (Phase 7 material - moves to budget_categories table).
-- Both COA-032 duplicates deactivate here since the "GROWTH" is a budget category and the
-- "Pre-2025 Carryforward" plug row is superseded by master 3100.
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code IN ('COA-019','COA-020','COA-021','COA-022','COA-031','COA-032')
   AND is_active = true;

-- Legacy budget-category row on PaperNewt (Phase 7 material)
UPDATE public.chart_of_accounts SET is_active = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND account_code = 'COA-PN-020'
   AND is_active = true;

-- =====================================================================
-- SECTION 3: Cleanup helper function
-- =====================================================================
DROP FUNCTION IF EXISTS public._phase3_rekey_account(uuid, text, text, text);

