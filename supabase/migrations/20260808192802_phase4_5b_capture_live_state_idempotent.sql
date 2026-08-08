-- Idempotent capture of all rule/mapping/data changes applied via raw SQL in this
-- rebuild session (planning_thread_20260808), so the repo can reproduce live state.

-- 13 gl_classification_rules rows (5 SKIP, 5 income/rebate, 3 bank interest)
INSERT INTO public.gl_classification_rules
  (id, agency_id, rule_name, match_priority, match_direction, debit_account_code, credit_account_code,
   confidence, source, is_active, match_payee_regex, match_source_account)
SELECT * FROM (VALUES
  ('1ef8ec20-8e77-47ef-9158-05e5e349e3c9'::uuid, '126794dd-25ff-47d2-a436-724499733365'::uuid, 'SKIP — credit card payment legs', 1, 'both', '__SKIP__', '__SKIP__', 'high', 'planning_thread_20260808', true,
   '(?i)(^credit\s+card\b)|(internet\s+banking\s+payment\s+to\s+credit\s+card)|(internet\s+payment\s*[-–—]?\s*thank\s+you)|(online\s+payment,?\s*thank\s+you)|(amex\s+epayment)', NULL::text),
  ('cea3b31a-c799-4380-ac08-a65dbb2b83b7', '126794dd-25ff-47d2-a436-724499733365', 'SKIP — internal bank transfer legs', 1, 'both', '__SKIP__', '__SKIP__', 'high', 'planning_thread_20260808', true,
   '(?i)(internet\s+banking\s+transfer)|(^account\s+[0-9]{9,})', NULL),
  ('a3ea8417-776d-4f61-a548-58cd748c9f36', '126794dd-25ff-47d2-a436-724499733365', 'SKIP — State Farm commission deposit (income comes from comp_recap)', 1, 'both', '__SKIP__', '__SKIP__', 'high', 'planning_thread_20260808', true,
   '(?i)agencycomp', NULL),
  ('fa24c5e4-3049-48fa-9edd-8fc4e7221e7d', '126794dd-25ff-47d2-a436-724499733365', 'SKIP — payroll cash out (expense comes from payroll_gl_writer)', 1, 'both', '__SKIP__', '__SKIP__', 'high', 'planning_thread_20260808', true,
   '(?i)^payroll\s+service\b', NULL),
  ('3c4d24ef-d49d-4db0-9ec9-82b264e47640', '126794dd-25ff-47d2-a436-724499733365', 'SKIP — HSA investment valuation marker (not cash)', 1, 'both', '__SKIP__', '__SKIP__', 'high', 'planning_thread_20260808', true,
   '(?i)change\s+in\s+investment\s+value', NULL),
  ('01010586-989a-461e-8db2-ccf67aa66733', '126794dd-25ff-47d2-a436-724499733365', 'Card cash-back reward', 10, 'credit', '6945', '6945', 'high', 'planning_thread_20260808', true,
   '(?i)(cash[-\s]?back\s+reward)|(credit-cash\s+back)', NULL),
  ('f327a03a-a7a4-4d5d-ba0c-3b062530c951', '126794dd-25ff-47d2-a436-724499733365', 'Gloelle W-2 paycheck deposit', 10, 'credit', '8120', '8120', 'high', 'planning_thread_20260808', true,
   '(?i)glo?ele?le?\s+llc', NULL),
  ('b75044c2-1dba-434d-b050-00bd9bf8e1a5', '126794dd-25ff-47d2-a436-724499733365', 'Credit union dividend', 10, 'credit', '8200', '8200', 'high', 'planning_thread_20260808', true,
   '(?i)^dividend', NULL),
  ('caf1c0c6-3aeb-4c1f-8145-58c49b0f7b17', '126794dd-25ff-47d2-a436-724499733365', 'Eriosto SMVC trucking revenue', 10, 'credit', '4400', '4400', 'high', 'planning_thread_20260808', true,
   '(?i)(smvc\s+truckin)|(eriosto\s+tanker\s+rental)', NULL),
  ('89ab719f-9b8c-45b0-98bd-d9eba20e9466', '126794dd-25ff-47d2-a436-724499733365', 'PaperNewt W-2 paycheck deposit', 10, 'credit', '8110', '8110', 'high', 'planning_thread_20260808', true,
   '(?i)(papernewt\s+llc.*payroll)|(payroll.*papernewt\s+llc)', NULL),
  ('85cc89c1-801f-4122-87c5-dea2f3f971e3', '126794dd-25ff-47d2-a436-724499733365', 'Bank interest — US Bank Kids Profit Disc → personal interest income', 10, 'credit', '8200', '8200', 'high', 'planning_thread_20260808', true,
   '(?i)^interest\s+paid', '1072'),
  ('386ba0d6-f250-478e-a903-3c18bee1e1d2', '126794dd-25ff-47d2-a436-724499733365', 'Bank interest — US Bank Expenses 4335 → agency interest income', 10, 'credit', '4920', '4920', 'high', 'planning_thread_20260808', true,
   '(?i)^interest\s+paid', '1011'),
  ('db8cb019-a87d-44ab-a1c1-34a5d161eb28', '126794dd-25ff-47d2-a436-724499733365', 'Bank interest — US Bank Tithe Tax → personal interest income', 10, 'credit', '8200', '8200', 'high', 'planning_thread_20260808', true,
   '(?i)^interest\s+paid', '1073')
) AS v(id, agency_id, rule_name, match_priority, match_direction, debit_account_code, credit_account_code, confidence, source, is_active, match_payee_regex, match_source_account)
WHERE NOT EXISTS (SELECT 1 FROM public.gl_classification_rules r WHERE r.id = v.id);

-- Delete the catch-all suspense rule and any other rule targeting 0005 (guarded)
DELETE FROM public.gl_classification_rules
WHERE (debit_account_code = '0005' OR credit_account_code = '0005')
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- Deactivate the auto-loan rule (same as 4.5a — idempotent, migration self-sufficient)
UPDATE public.gl_classification_rules
   SET is_active = false,
       override_reason = CASE
         WHEN override_reason LIKE '%deactivated 2026-08-08%' THEN override_reason
         ELSE COALESCE(override_reason, '') ||
           ' [deactivated 2026-08-08: targets 2540 Vehicle Loan Payable. The '
           'balance-sheet guard would skip the whole payment and hide its '
           'interest portion. Loan payments must land in Unclassified Expense '
           'for review. Loan interest will be ingested from lender year-end '
           'statements as its own canon row in separate work.]'
       END,
       updated_at = CASE WHEN is_active THEN NOW() ELSE updated_at END
 WHERE id = '607a0550-f8eb-47c6-9b30-d78fbe452263';

-- 5 comp_deduction_map rows from Phase 4a (guarded on id)
INSERT INTO public.comp_deduction_map
  (id, agency_id, source_business_entity_id, is_active, comp_category, description_pattern,
   source_account_code, source_account_name, source_parent_account_name, priority)
SELECT * FROM (VALUES
  ('17ba0bda-ba5a-43ce-ac38-7682d7d9719d'::uuid, '126794dd-25ff-47d2-a436-724499733365'::uuid, 'b2222222-2222-2222-2222-222222222222'::uuid, true,
   'deduction_medical', NULL::text, '6115', 'S-Corp Medical — Owner', '0001 ADMINISTRATION 6% > 5%> 5%', 100),
  ('26011899-1c92-4ed7-90b0-d17c42044e65', '126794dd-25ff-47d2-a436-724499733365', 'b2222222-2222-2222-2222-222222222222', true,
   'deduction_credit_union', NULL, '__SKIP__', 'Skipped — credit union savings transfer, no profit or loss effect', 'Skipped — no budget bucket', 100),
  ('b83a065b-ac6b-4e96-90c5-8b71b14ca7f7', '126794dd-25ff-47d2-a436-724499733365', 'b2222222-2222-2222-2222-222222222222', true,
   'deduction_other', 'AGENTS (GROUP MEDICAL|DENTAL|VISION)', '6115', 'S-Corp Medical — Owner (reversal)', '0001 ADMINISTRATION 6% > 5%> 5%', 50),
  ('f5853f50-32a3-46e7-bb3a-d69e72e20664', '126794dd-25ff-47d2-a436-724499733365', 'b2222222-2222-2222-2222-222222222222', true,
   'deduction_other', 'CREDIT UNION', '__SKIP__', 'Skipped — credit union savings transfer reversal, no profit or loss effect', 'Skipped — no budget bucket', 50),
  ('9936b90f-ae4b-469b-a72d-396122013faa', '126794dd-25ff-47d2-a436-724499733365', 'b2222222-2222-2222-2222-222222222222', true,
   'deduction_other', NULL, '6950', 'Miscellaneous', '0001 ADMINISTRATION 6% > 5%> 5%', 100)
) AS v(id, agency_id, source_business_entity_id, is_active, comp_category, description_pattern, source_account_code, source_account_name, source_parent_account_name, priority)
WHERE NOT EXISTS (SELECT 1 FROM public.comp_deduction_map d WHERE d.id = v.id);

-- statement ddaaca91-... transaction_type fix (guarded on still-NULL)
UPDATE public.statements
   SET transaction_type = 'deposit',
       notes = COALESCE(notes, '') ||
         ' [transaction_type set to deposit 2026-08-08: was NULL from the '
         '2026-07-29 manual backfill. Direction confirmed against the '
         '2026-06-25..2026-07-23 statement for account code 1011 — opening '
         '75039.22 + deposits 39940.26 + 170.51 - withdrawals 37670.60 = '
         'closing 77479.39 exactly.]'
 WHERE id = 'ddaaca91-595b-4c4c-9f7b-1a07b277ed9c' AND transaction_type IS NULL;

-- chart_of_accounts 4920 Interest Income on the agency entity (guarded)
INSERT INTO public.chart_of_accounts
  (agency_id, business_entity_id, account_code, account_name, account_type,
   account_subtype, section_label_override, is_active, is_system, description)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid,
       'b2222222-2222-2222-2222-222222222222'::uuid,
       '4920', 'Interest Income', 'income', 'other', 'Other Income',
       true, false,
       'Bank interest credited to agency operating accounts. Not State Farm '
       'compensation — deliberately outside the SF section labels.'
WHERE NOT EXISTS (
  SELECT 1 FROM public.chart_of_accounts
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
     AND business_entity_id = 'b2222222-2222-2222-2222-222222222222'::uuid
     AND account_code = '4920');
