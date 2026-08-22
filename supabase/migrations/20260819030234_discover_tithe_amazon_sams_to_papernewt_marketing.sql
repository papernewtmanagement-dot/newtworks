
-- Peter directive 2026-08-18 (follow-up): Discover Tithe card (3208 / chart code 2171)
-- Amazon + Sam's Club charges also move to PaperNewt, to the marketing account (6400).
-- The old "Amazon on Discover -> Tithe (Vault donations)" rule (priority 110) never
-- actually fired on real data -- the one Amazon charge on this card ($2005.41) sat in
-- Personal/Kids, not Tithe. Deactivating it in favor of the new rule.

UPDATE gl_classification_rules
SET is_active = false
WHERE id = '247e9cac-9e14-4271-9677-df99c3ce407e'; -- Amazon on Discover -> Tithe (Vault donations)

INSERT INTO gl_classification_rules
  (agency_id, rule_name, match_payee_regex, match_source_account, match_direction,
   target_business_entity_id, debit_account_code, credit_account_code, match_priority,
   confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'Amazon — Discover Tithe (2171) → PaperNewt 6400',
   '\yamazon\y|\yamzn\y', '2171', 'both',
   'b1111111-1111-1111-1111-111111111111', '6400', '6400', 55, 'high', 'claude_2026-08-18', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Sams Club — Discover Tithe (2171) → PaperNewt 6400',
   '(?i)SAM.?S\s*CLUB|SAMSCLUB', '2171', 'both',
   'b1111111-1111-1111-1111-111111111111', '6400', '6400', 55, 'high', 'claude_2026-08-18', true);

-- Backfill: Amazon + Sam's Club on 3208 -> PaperNewt 6400
WITH target AS (SELECT id FROM chart_of_accounts WHERE account_code='6400' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
moved AS (
  UPDATE ledger l
  SET original_account_id = COALESCE(l.original_account_id, l.account_id),
      original_account_code = COALESCE(l.original_account_code, (SELECT account_code FROM chart_of_accounts WHERE id = l.account_id)),
      original_account_name = COALESCE(l.original_account_name, (SELECT account_name FROM chart_of_accounts WHERE id = l.account_id)),
      account_id = (SELECT id FROM target),
      classification_status = 'classified',
      classified_by = 'rule',
      classified_at = now(),
      rule_id_used = (SELECT id FROM gl_classification_rules WHERE rule_name = CASE
        WHEN l.description ~* '\yamazon\y|\yamzn\y' THEN 'Amazon — Discover Tithe (2171) → PaperNewt 6400'
        ELSE 'Sams Club — Discover Tithe (2171) → PaperNewt 6400' END)
  FROM statements st, accounts a
  WHERE l.statement_id = st.id AND st.account_id = a.id
    AND a.account_number_last4 = '3208'
    AND (l.description ~* '\yamazon\y|\yamzn\y|SAM.?S\s*CLUB|SAMSCLUB')
  RETURNING l.id, l.debit, l.credit
)
INSERT INTO account_reclassifications
  (agency_id, from_account_id, to_account_id, filter_description, journal_line_count, total_amount, performed_by, notes, from_business_entity_id)
SELECT '126794dd-25ff-47d2-a436-724499733365',
  NULL, (SELECT id FROM target),
  'Amazon + Sams Club on Discover Tithe (3208) — Peter directive 2026-08-18 follow-up: move to PaperNewt marketing',
  count(*), sum(GREATEST(debit,credit)), 'claude', 'Old vault-donation rule for this card never actually fired on real data; deactivated and superseded',
  'b3333333-3333-3333-3333-333333333333'
FROM moved;

