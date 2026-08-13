-- 1) THE BUG: in Postgres regular expressions \b means the BACKSPACE character,
--    not a word boundary. The word-boundary token is \y. Twenty-four active rules
--    used \b, so those branches could never match anything. This is why the
--    "Credit Card ****3447" card-payoff legs were never skipped despite an
--    existing rule anchored on ^credit\s+card\b.
UPDATE gl_classification_rules
SET match_payee_regex = replace(match_payee_regex, '\b', '\y'),
    updated_at = NOW(),
    override_reason = COALESCE(override_reason || ' | ', '')
      || 'Regex repaired 2026-08-13: \b is backspace in Postgres, replaced with \y word boundary.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND strpos(COALESCE(match_payee_regex, ''), '\b') > 0;

UPDATE gl_classification_rules
SET match_memo_regex = replace(match_memo_regex, '\b', '\y'),
    updated_at = NOW(),
    override_reason = COALESCE(override_reason || ' | ', '')
      || 'Regex repaired 2026-08-13: \b is backspace in Postgres, replaced with \y word boundary.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND strpos(COALESCE(match_memo_regex, ''), '\b') > 0;

-- 2) Peter directive: the recurring $1,250 Venmo payments are the agency's rent.
--    Amount-pinned to 1250 so the other Venmo amounts (which are different
--    things) are not swept in.
INSERT INTO gl_classification_rules (
  agency_id, rule_name, match_priority, match_payee_regex, match_direction,
  match_amount_min, match_amount_max, debit_account_code, credit_account_code,
  target_business_entity_id, sub_category_label, confidence, source
)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid,
       'Venmo $1,250 recurring — agency rent', 25,
       '(?i)^venmo\y', 'debit', 1250, 1250, '6210', '__SOURCE__',
       'b2222222-2222-2222-2222-222222222222',
       'Agency rent', 'high', 'peter_directive_20260813'
WHERE NOT EXISTS (
  SELECT 1 FROM gl_classification_rules
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND rule_name = 'Venmo $1,250 recurring — agency rent');

-- 3) Peter directive: card payoff legs are payoffs, ignore them. Explicit rule on
--    the masked-card-number shape, so this does not depend on the description
--    happening to start with "Credit Card".
INSERT INTO gl_classification_rules (
  agency_id, rule_name, match_priority, match_payee_regex, match_direction,
  debit_account_code, credit_account_code, confidence, source
)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid,
       'SKIP — credit card payoff leg (masked card number)', 1,
       '(?i)credit\s+card\s*[-–—]?\s*\*{2,}\s*[0-9]{4}', 'both',
       '__SKIP__', '__SKIP__', 'high', 'peter_directive_20260813'
WHERE NOT EXISTS (
  SELECT 1 FROM gl_classification_rules
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND rule_name = 'SKIP — credit card payoff leg (masked card number)');

-- 4) Peter directive: put the EIDL payments back. Deactivating the rule that
--    routed them to the loan liability account, because that rule's only effect
--    was to keep them out of the ledger entirely.
UPDATE gl_classification_rules
SET is_active = FALSE, updated_at = NOW(),
    override_reason = 'Deactivated 2026-08-13 per Peter: EIDL payments stay in the ledger.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_name = 'SBA EIDL loan payment — PaperNewt principal (balance sheet)';

-- Restore the exact rows that were removed, from the pre-backfill snapshot.
-- (ledger_unclassified_backfill_20260813 is the snapshot taken before the
-- 2026-08-13 suspense-account backfill; on a fresh reset it will not exist and
-- this statement is a no-op, which is correct since the rows it restores were
-- never removed in that scenario.)
INSERT INTO ledger (
  id, agency_id, entry_date, account_id, debit, credit, description, source,
  reference_number, statement_id, rule_id_used, classification_status,
  classified_by, classified_at, entry_type
)
SELECT b.id, b.agency_id, b.entry_date, b.account_id, b.debit, b.credit,
       b.description, b.source, b.reference_number, b.statement_id, b.rule_id_used,
       b.classification_status, b.classified_by, b.classified_at, b.entry_type
FROM ledger_unclassified_backfill_20260813 b
WHERE b.description ~* 'sba\s+eidl\s+loan'
  AND NOT EXISTS (SELECT 1 FROM ledger l WHERE l.statement_id = b.statement_id);
