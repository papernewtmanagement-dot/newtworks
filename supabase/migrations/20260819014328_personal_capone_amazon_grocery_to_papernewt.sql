
-- Peter directive 2026-08-18: Amazon, HEB, Sam's Club, Costco, Sprouts on the
-- Capital One Personal card (7435 / chart code 2172) are misapplied to Personal.
-- They belong to PaperNewt LLC. Fix going forward (rules) AND backfill all history
-- on this card. Discover Tithe (3208) deliberately left alone (existing vault-donation rule).

-- 1. Forward-looking rules, scoped to card 2172 only, priority 55 (beats the
--    generic Personal fallback rules at priority 90).
INSERT INTO gl_classification_rules
  (agency_id, rule_name, match_payee_regex, match_source_account, match_direction,
   target_business_entity_id, debit_account_code, credit_account_code, match_priority,
   confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'Amazon — Capital One Personal (2172) → PaperNewt 6400',
   '\yamazon\y|\yamzn\y', '2172', 'both',
   'b1111111-1111-1111-1111-111111111111', '6400', '6400', 55, 'high', 'claude_2026-08-18', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'H-E-B — Capital One Personal (2172) → PaperNewt 6910',
   '(?i)H-E-B|HEB\y', '2172', 'both',
   'b1111111-1111-1111-1111-111111111111', '6910', '6910', 55, 'high', 'claude_2026-08-18', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Sams Club — Capital One Personal (2172) → PaperNewt 6910',
   '(?i)SAM.?S\s*CLUB|SAMSCLUB', '2172', 'both',
   'b1111111-1111-1111-1111-111111111111', '6910', '6910', 55, 'high', 'claude_2026-08-18', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Costco Wholesale — Capital One Personal (2172) → PaperNewt 6910',
   '(?i)COSTCO\s+(WHSE|WAREHOUSE)', '2172', 'both',
   'b1111111-1111-1111-1111-111111111111', '6910', '6910', 55, 'high', 'claude_2026-08-18', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Sprouts — Capital One Personal (2172) → PaperNewt 6910',
   '(?i)SPROUTS', '2172', 'both',
   'b1111111-1111-1111-1111-111111111111', '6910', '6910', 55, 'high', 'claude_2026-08-18', true);

-- 2. Backfill: Amazon on 7435 -> PaperNewt 6400 (219 rows, incl. the 98 previously unclassified)
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
      rule_id_used = (SELECT id FROM gl_classification_rules WHERE rule_name = 'Amazon — Capital One Personal (2172) → PaperNewt 6400')
  FROM statements st, accounts a
  WHERE l.statement_id = st.id AND st.account_id = a.id
    AND a.account_number_last4 = '7435'
    AND (l.description ~* '\yamazon\y|\yamzn\y')
  RETURNING l.id, l.debit, l.credit
)
INSERT INTO account_reclassifications
  (agency_id, from_account_id, to_account_id, filter_description, journal_line_count, total_amount, performed_by, notes, from_business_entity_id)
SELECT '126794dd-25ff-47d2-a436-724499733365',
  (SELECT id FROM chart_of_accounts WHERE account_code='0004' AND business_entity_id='b3333333-3333-3333-3333-333333333333'),
  (SELECT id FROM target),
  'Amazon charges on Capital One Personal (7435) — Peter directive 2026-08-18: misapplied to Personal, belong to PaperNewt',
  count(*), sum(GREATEST(debit,credit)), 'claude', 'Backfill of pre-existing Amazon classifications (Kids/Medical/Clothing/Groceries/Home Maint) + unclassified pile, all moved to PaperNewt 6400',
  'b3333333-3333-3333-3333-333333333333'
FROM moved;

-- 3. Backfill: HEB/Sam's/Costco/Sprouts on 7435 -> PaperNewt 6910
WITH target AS (SELECT id FROM chart_of_accounts WHERE account_code='6910' AND business_entity_id='b1111111-1111-1111-1111-111111111111'),
moved AS (
  UPDATE ledger l
  SET original_account_id = COALESCE(l.original_account_id, l.account_id),
      original_account_code = COALESCE(l.original_account_code, (SELECT account_code FROM chart_of_accounts WHERE id = l.account_id)),
      original_account_name = COALESCE(l.original_account_name, (SELECT account_name FROM chart_of_accounts WHERE id = l.account_id)),
      account_id = (SELECT id FROM target),
      classification_status = 'classified',
      classified_by = 'rule',
      classified_at = now(),
      rule_id_used = (SELECT id FROM gl_classification_rules WHERE rule_name ILIKE '%Capital One Personal (2172) → PaperNewt 6910%' AND rule_name ILIKE
        (CASE
          WHEN l.description ~* '(?i)H-E-B|HEB\y' THEN '%H-E-B%'
          WHEN l.description ~* '(?i)SAM.?S\s*CLUB|SAMSCLUB' THEN '%Sams Club%'
          WHEN l.description ~* '(?i)COSTCO\s+(WHSE|WAREHOUSE)' THEN '%Costco%'
          WHEN l.description ~* '(?i)SPROUTS' THEN '%Sprouts%'
        END))
  FROM statements st, accounts a
  WHERE l.statement_id = st.id AND st.account_id = a.id
    AND a.account_number_last4 = '7435'
    AND (l.description ~* '(?i)H-E-B|HEB\y|SAM.?S\s*CLUB|SAMSCLUB|COSTCO\s+(WHSE|WAREHOUSE)|SPROUTS')
  RETURNING l.id, l.debit, l.credit
)
INSERT INTO account_reclassifications
  (agency_id, from_account_id, to_account_id, filter_description, journal_line_count, total_amount, performed_by, notes, from_business_entity_id)
SELECT '126794dd-25ff-47d2-a436-724499733365',
  (SELECT id FROM chart_of_accounts WHERE account_code='9200' AND business_entity_id='b3333333-3333-3333-3333-333333333333'),
  (SELECT id FROM target),
  'HEB/Sams/Costco/Sprouts on Capital One Personal (7435) — Peter directive 2026-08-18: misapplied to Personal, belong to PaperNewt',
  count(*), sum(GREATEST(debit,credit)), 'claude', 'Backfill of pre-existing Groceries classifications, moved to PaperNewt 6910',
  'b3333333-3333-3333-3333-333333333333'
FROM moved;

