-- Part 1: fix the one bad data row
UPDATE public.statements
   SET transaction_type = 'deposit',
       notes = COALESCE(notes, '') ||
         ' [transaction_type set to deposit 2026-08-08: was NULL from the '
         '2026-07-29 manual backfill. Direction confirmed against the '
         '2026-06-25..2026-07-23 statement for account code 1011 — opening '
         '75039.22 + deposits 39940.26 + 170.51 - withdrawals 37670.60 = '
         'closing 77479.39 exactly.]'
 WHERE id = 'ddaaca91-595b-4c4c-9f7b-1a07b277ed9c';

-- Part 2: create the missing agency interest income account
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

-- Part 3: three new classification rules for bank interest
INSERT INTO gl_classification_rules
  (agency_id, rule_name, match_priority, match_direction, debit_account_code, credit_account_code,
   confidence, source, is_active, match_payee_regex, match_source_account)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'Bank interest — US Bank Expenses 4335 → agency interest income', 10, 'credit', '4920', '4920', 'high', 'planning_thread_20260808', true, '(?i)^interest\s+paid', '1011'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Bank interest — US Bank Kids Profit Disc → personal interest income', 10, 'credit', '8200', '8200', 'high', 'planning_thread_20260808', true, '(?i)^interest\s+paid', '1072'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Bank interest — US Bank Tithe Tax → personal interest income', 10, 'credit', '8200', '8200', 'high', 'planning_thread_20260808', true, '(?i)^interest\s+paid', '1073');