-- Batch-3 item 5a: RED DRAGON PIRATE CRUISES had no gl_classification_rules
-- entry, so its legs (2x 10.00 recovered occurrences + 1x 123.05, all
-- 2026-03-25 on AMEX 2141) fell to 0003 Unclassified Expense. Personal
-- excursion -> 9800 Discretionary, same landing as the sibling PLARIUM
-- charges from the same statements. Rule mirrors the Plarium rule's shape
-- (debit 9800, credit __SOURCE__, direction both, same priority/confidence).
WITH plarium AS (
  SELECT match_priority, confidence
  FROM gl_classification_rules
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND rule_name = 'Plarium — personal mobile gaming'
  LIMIT 1
), new_rule AS (
  INSERT INTO gl_classification_rules
    (agency_id, rule_name, match_priority, match_payee_regex,
     debit_account_code, credit_account_code, match_direction,
     confidence, source, is_active, created_at, updated_at)
  SELECT '126794dd-25ff-47d2-a436-724499733365',
         'Red Dragon Pirate Cruises — personal excursion',
         p.match_priority, '(?i)RED\s+DRAGON\s+PIRATE',
         '9800', '__SOURCE__', 'both',
         p.confidence, 'claude_recon_batch3', true, NOW(), NOW()
  FROM plarium p
  RETURNING id
), target AS (
  -- Same 9800 account row the classified PLARIUM legs already use.
  SELECT l.account_id AS acct_id
  FROM ledger l
  WHERE l.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND l.description ILIKE '%PLARIUM%'
    AND l.classification_status = 'classified'
  LIMIT 1
), upd AS (
  UPDATE ledger l
  SET account_id = t.acct_id,
      classification_status = 'classified',
      rule_id_used = nr.id,
      classified_by = 'rule:' || nr.id::text,
      classified_at = NOW()
  FROM new_rule nr, target t
  WHERE l.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND l.description ILIKE '%RED DRAGON PIRATE CRUISES%'
    AND l.classification_status = 'unclassified'
  RETURNING l.id
)
UPDATE gl_classification_rules r
SET historical_uses = COALESCE(historical_uses, 0) + (SELECT count(*) FROM upd),
    last_used_at = NOW()
WHERE r.id = (SELECT id FROM new_rule);
-- Post-apply note: the CTE count above evaluated to 0 at apply time (CTE
-- visibility quirk); historical_uses was corrected to 3 by a direct UPDATE
-- in the same session. Legs verified on 9800 Discretionary, classified.
