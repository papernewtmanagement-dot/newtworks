-- Round 5: reprocess the 8 provisional August cash-register ledger rows against
-- today's FIX 7 rule matching and FIX 10 card-payment guard. Applied via
-- Supabase MCP 2026-08-14 evening.

-- 1. New rule (Peter directive, live in this conversation): WebCE -> Agency
-- Continuing Education & Training (Team), not the growth/hiring bucket.
INSERT INTO gl_classification_rules (
  agency_id, rule_name, match_priority, match_payee_regex, match_source_account,
  match_direction, debit_account_code, credit_account_code, target_business_entity_id,
  sub_category_label, confidence, source
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365', 'WebCE -> Agency Continuing Ed & Training (Team)',
  20, '(?i)webce', NULL, 'both', '6720', '6720', 'b2222222-2222-2222-2222-222222222222',
  'Continuing education / licensing training', 'high', 'peter_directive_20260814_round5'
);

-- 2. Indeed job-ad charge -> Recruitment Costs (existing rule
--    "Historical Import #28: Recruiting - Ads", id bc31a6a6-2572-466c-872a-b11aa720fe75)
UPDATE ledger
SET original_account_id = account_id,
    original_account_code = '0003',
    original_account_name = '*Unclassified Expense — Business',
    account_id = '81c0a64d-49ff-42f8-b117-aea619bfb088',
    classification_status = 'classified',
    rule_id_used = 'bc31a6a6-2572-466c-872a-b11aa720fe75',
    classified_by = 'rule:bc31a6a6-2572-466c-872a-b11aa720fe75',
    classified_at = NOW(),
    suspense_reason = NULL
WHERE id = 'c52583b5-b8fc-4a99-8035-88300fdd26b7';

-- 3. WebCE charge -> Continuing Ed & Training, via the new rule above
UPDATE ledger
SET original_account_id = account_id,
    original_account_code = '0003',
    original_account_name = '*Unclassified Expense — Business',
    account_id = '0bce4ec5-c5b7-48dc-93ad-fa9b5cc504eb',
    classification_status = 'classified',
    rule_id_used = (SELECT id FROM gl_classification_rules WHERE rule_name = 'WebCE -> Agency Continuing Ed & Training (Team)'),
    classified_by = 'rule:' || (SELECT id::text FROM gl_classification_rules WHERE rule_name = 'WebCE -> Agency Continuing Ed & Training (Team)'),
    classified_at = NOW(),
    suspense_reason = NULL
WHERE id = '50921957-72c0-4bb9-a631-060cb390755c';

-- 4. Amazon Marketplace charge -> stays in 0003 (already the correct target per
--    rule "Amazon on US Bank 3447 family -> agency unclassified expense",
--    id 68c513f3-5c0d-4e69-b39a-ff3af64826ca) — flips status to classified and
--    attaches the rule so it's no longer silently unclassified.
UPDATE ledger
SET original_account_id = account_id,
    original_account_code = '0003',
    original_account_name = '*Unclassified Expense — Business',
    account_id = 'c7abc933-2328-4388-bce8-f82c88874537',
    classification_status = 'classified',
    rule_id_used = '68c513f3-5c0d-4e69-b39a-ff3af64826ca',
    classified_by = 'rule:68c513f3-5c0d-4e69-b39a-ff3af64826ca',
    classified_at = NOW(),
    suspense_reason = NULL
WHERE id = '7af68e22-1bdd-4aa2-99c8-a4ba4930a80f';

-- 5. $5,460.25 US Bank Expenses debit (register id 6cf867e3) matches the FIX 10
-- card-payment guard: exact match to the US Bank Business Cash Rewards (3447)
-- statement closing balance for the period ending 2026-07-15. Not a real
-- expense — it's the agency paying off its own credit card. Delete the
-- provisional ledger row and mark the register row a possible transfer so the
-- statement pass can claim it later.
DELETE FROM ledger WHERE id = 'b853e6f1-99e4-4c3d-b572-61e8aecd180c';

UPDATE cash_register_preliminary
SET status = 'possible_transfer',
    coding_question = 'Looks like a payment to one of our credit cards — waiting for the statement to confirm.',
    updated_at = NOW()
WHERE id = '6cf867e3-0550-467b-9ecc-24194ab577e8';

-- 6. The remaining 4 provisional rows (2 debits at 3977, 1 debit at 3977, 1
-- credit at 3977 — all $10,000.00 / $7,241.69 / $6,309.84 / $19,017.83, all
-- with no merchant text) carry no merchant to match rules against and no
-- card-payment match. They are left as-is, still unclassified, still
-- awaiting_statement — by design, no action taken.
