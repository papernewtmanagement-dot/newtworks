-- Pass 1 of the merchant walk: 68 pending gl_entry_writer JEs are SF deduction statement lines
-- with no matching classification rule. Seed 10 new rules, broaden 1 existing.
--
-- All patterns land on the DEBIT side (deduction lines DEBIT expense, CREDIT source bank COA-007).
-- credit_account_code=__SOURCE__ preserves whatever the counterparty account was (COA-007 here).
-- Priority 50 = beat any generic 100-level rules; specific SF patterns should always win.

-- Broaden the existing SFD.CREDIT UNION rule to also catch plain "CREDIT UNION"
-- (SF deduction statement writes just "CREDIT UNION"; bank memo variant is "SFD CREDIT UNION").
UPDATE public.gl_classification_rules
SET match_payee_regex = 'CREDIT UNION',
    rule_name = 'Auto loan — SFD/Credit Union (broadened for SF deduction lines)'
WHERE id = '607a0550-f8eb-47c6-9b30-d78fbe452263';

-- 10 new rules for the SF deduction statement patterns.
INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, confidence, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Agents Group Medical',
   50, 'AGENTS GROUP MEDICAL', 'debit', 'COA-SUB-077', '__SOURCE__', 'exact', TRUE),

  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Agents Dental Ins',
   50, 'AGENTS DENTAL INS', 'debit', 'COA-SUB-077', '__SOURCE__', 'exact', TRUE),

  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Agents Vision Coverage',
   50, 'AGENTS VISION COVERAGE', 'debit', 'COA-SUB-077', '__SOURCE__', 'exact', TRUE),

  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Appointment/Termination Fees Agent Staff',
   50, 'APPOINTMENT/TERMINATION FEES AGENT STAFF', 'debit', 'COA-SUB-073', '__SOURCE__', 'exact', TRUE),

  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Appointment Renewal Fees Agents Staff',
   50, 'APPOINTMENT RENEWAL FEES AGENTS STAFF', 'debit', 'COA-SUB-073', '__SOURCE__', 'exact', TRUE),

  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Appointment Renewal Fees Agent',
   50, 'APPOINTMENT RENEWAL FEES AGENT($|[^S])', 'debit', 'COA-SUB-023', '__SOURCE__', 'exact', TRUE),

  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Appointment Fees Agent',
   50, '^APPOINTMENT FEES AGENT', 'debit', 'COA-SUB-023', '__SOURCE__', 'exact', TRUE),

  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: MySFDomain Services',
   50, 'MYSFDOMAIN SERVICES', 'debit', '6470', '__SOURCE__', 'exact', TRUE),

  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Agent Equipment Lease',
   50, 'AGENT EQUIPMENT LEASE', 'debit', 'COA-SUB-037', '__SOURCE__', 'exact', TRUE),

  ('126794dd-25ff-47d2-a436-724499733365', 'SF deduction: Echo Co-op Direct Mail',
   50, 'ECHO CO-OP DIRECT MAIL', 'debit', 'COA-SUB-049', '__SOURCE__', 'exact', TRUE);

-- Sweep pending JEs — retroactively apply the new rules.
SELECT public.reclassify_pending_je(
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  NULL,   -- any source account
  NULL,   -- all pending JEs
  false   -- NOT dry run
) AS result;
