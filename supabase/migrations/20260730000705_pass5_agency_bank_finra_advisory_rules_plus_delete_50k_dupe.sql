-- Pass 5: two more SF-deduction rules (FINRA + Advisory renewal fees) and 50k duplicate cleanup.

-- 1. FINRA + Advisory renewal fees → COA-SUB-023 Dues & Licenses - AGENT.
INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, confidence, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: FINRA Renewal Fee - Agent',
   50, 'FINRA RENEWAL FEE - AGENT', 'debit', 'COA-SUB-023', '__SOURCE__', 'exact', TRUE),
  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Advisory Renewal Fee - Agent',
   50, 'ADVISORY RENEWAL FEE-AGENT', 'debit', 'COA-SUB-023', '__SOURCE__', 'exact', TRUE);

-- 2. Delete the orphan claude_bank_reparse 50k duplicate; keep the bank_gl_writer JE (linked to bank_transactions).
DELETE FROM public.journal_lines WHERE journal_entry_id = '699738d3-e055-43d5-8701-7b4d47749864';
DELETE FROM public.journal_entries WHERE id = '699738d3-e055-43d5-8701-7b4d47749864';

-- 3. Sweep pending JEs against the 2 new rules.
SELECT public.reclassify_pending_je(
  '126794dd-25ff-47d2-a436-724499733365'::uuid, NULL, NULL, false
) AS result;
