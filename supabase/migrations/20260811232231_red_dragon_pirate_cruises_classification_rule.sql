-- New GL classification rule for Red Dragon Pirate Cruises (personal excursion),
-- mirroring the existing Plarium rule pattern: routes to 9800 Discretionary.
INSERT INTO gl_classification_rules (
  rule_name, match_priority, match_payee_regex, match_source_account,
  debit_account_code, credit_account_code, match_direction
) VALUES (
  'Red Dragon Pirate Cruises — personal excursion',
  100,
  '(?i)RED\s+DRAGON\s+PIRATE',
  NULL,
  '9800', '__SOURCE__',
  'both'
);

-- Reclassify the three unclassified ledger legs from 2026-03-25 that this rule
-- covers (0003 -> 9800 Discretionary), and mark them as classified via this rule.
UPDATE ledger l
SET account_code = '9800',
    is_classified = true,
    rule_id_used = (SELECT id FROM gl_classification_rules WHERE rule_name = 'Red Dragon Pirate Cruises — personal excursion')
WHERE l.transaction_date = '2026-03-25'
  AND l.account_code = '0003'
  AND l.description ILIKE '%RED DRAGON PIRATE%';
