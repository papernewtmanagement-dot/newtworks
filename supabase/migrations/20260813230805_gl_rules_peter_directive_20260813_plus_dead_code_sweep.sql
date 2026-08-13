-- Ledger classification rules from Peter directive 2026-08-13, plus a same-class
-- sweep of rules pointing at chart-of-accounts codes that no longer exist.
--
-- Entity note: statement_gl_writer resolves an account_code by preferring the
-- paying statement's own entity, then falling back to any entity holding that
-- code. Codes that exist under exactly one entity (2511, 5100) therefore force
-- that entity. Codes held by two entities (6310, 6850, 6860, 6910) follow the
-- paying card.

-- ---------- 1. New rules ----------

INSERT INTO gl_classification_rules (
  agency_id, rule_name, match_priority, match_payee_regex, match_source_account,
  match_direction, debit_account_code, credit_account_code, sub_category_label,
  confidence, source
)
SELECT v.* FROM (VALUES
  -- Beats "AMEX Discretionary — Google -> 6310" (pri 5) and
  -- "Google YouTube / Play — Personal Discretionary" (pri 40).
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'Google TV — PaperNewt waiting-room entertainment', 4,
   '(?i)google\s*\*?\s*tv', '2141', 'both', '6310', '6310',
   'Waiting room entertainment for customers', 'high', 'peter_directive_20260813'),

  -- Loan principal is a balance-sheet movement, not an expense. 2511 exists only
  -- under PaperNewt, so this forces PaperNewt regardless of which account pays.
  -- The writer's balance-sheet guard will report these instead of posting a
  -- P&L row, which is the correct cash-basis outcome for principal.
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'SBA EIDL loan payment — PaperNewt principal (balance sheet)', 15,
   '(?i)sba\s+eidl\s+loan', NULL, 'both', '2511', '2511',
   'EIDL principal — PaperNewt', 'high', 'peter_directive_20260813'),

  -- Priority 30 sits BELOW the restaurant rules (pri 6 / 20) on purpose, so
  -- meals at these destinations stay in 6860 and only lodging, venue, marina,
  -- golf and other trip costs land in travel.
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'Horseshoe Bay — team meeting lodging & venue (PaperNewt)', 30,
   '(?i)horseshoe\s+bay', NULL, 'both', '6850', '6850',
   'Team meeting — Horseshoe Bay', 'high', 'peter_directive_20260813'),

  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'Port Aransas — team meeting lodging & venue (PaperNewt)', 30,
   '(?i)port\s+aransas', NULL, 'both', '6850', '6850',
   'Team meeting — Port Aransas', 'high', 'peter_directive_20260813'),

  -- PaperNewt has no advertising/marketing account, so giveaways land in the
  -- PaperNewt general expense account with the purpose carried in the label.
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'Bricks & Minifigs — customer giveaways (PaperNewt)', 30,
   '(?i)bricks\s*(and|&)\s*minifigs', NULL, 'both', '6910', '6910',
   'Customer giveaways', 'high', 'peter_directive_20260813'),

  -- Money-transfer legs: verification only, no journal entry either direction.
  -- \s*you catches both "THANK YOU" and "THANKYOU"; the existing pri-1 rule
  -- required whitespace and leaked the one-word variant.
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'SKIP — Internet Payment thank-you leg (money transfer)', 1,
   '(?i)internet\s+payment\s*[-–—]?\s*thank\s*you', NULL, 'both',
   '__SKIP__', '__SKIP__', NULL, 'high', 'peter_directive_20260813'),

  -- Widened from internet-only to every channel wording seen in the data.
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'SKIP — banking transfer legs, all channels (money transfer)', 1,
   '(?i)((internet|mobile|electronic|online)\s+banking\s+transfer)|(banking\s+transfer\s*[-–—]?\s*(to|from)\s+account)',
   NULL, 'both', '__SKIP__', '__SKIP__', NULL, 'high', 'peter_directive_20260813'),

  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'SKIP — Citi card online payment leg (money transfer)', 1,
   '(?i)citictp\s+payment|citi\s+card\s+online', NULL, 'both',
   '__SKIP__', '__SKIP__', NULL, 'high', 'peter_directive_20260813')
) AS v(agency_id, rule_name, match_priority, match_payee_regex, match_source_account,
       match_direction, debit_account_code, credit_account_code, sub_category_label,
       confidence, source)
WHERE NOT EXISTS (
  SELECT 1 FROM gl_classification_rules r
  WHERE r.agency_id = v.agency_id AND r.rule_name = v.rule_name
);

-- ---------- 2. ND4C: repair the dead source scope, per directive ----------
-- Rule was scoped to 'COA-PN-CC-1247'; the live code for that card is '2140',
-- so the rule never fired and all six ND4C charges sat in suspense.
UPDATE gl_classification_rules
SET match_source_account = '2140', updated_at = NOW(),
    override_reason = 'Source scope repaired COA-PN-CC-1247 -> 2140 (Peter directive 2026-08-13: ND4C = PaperNewt print costs)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_name = 'ND4C Houston -> PN Print COGS (Citi 1247)';

-- ---------- 3. Same-class sweep: rules aimed at deleted account codes ----------
-- 6311 / 6312 / 6313 / 6315 were removed from the chart; the rules survived and
-- silently dumped their matches into unclassified suspense.
UPDATE gl_classification_rules
SET debit_account_code = '6310', updated_at = NOW(),
    override_reason = 'Target repaired: 6311/6312/6313/6315 no longer exist; consolidated to 6310 Software & SaaS (sweep 2026-08-13)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active AND debit_account_code IN ('6311','6312','6313','6315');

-- Anthropic was never matched at all. Fold it into the repaired Claude rule.
UPDATE gl_classification_rules
SET match_payee_regex = '(?i)anthropic|claude\.ai', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_name = 'Claude.ai subscription';

-- 6715 was removed; licensing spend belongs in 6710 Dues & Licenses, which is
-- where every other licensing rule already points.
UPDATE gl_classification_rules
SET debit_account_code = '6710', updated_at = NOW(),
    override_reason = 'Target repaired: 6715 no longer exists; 6710 Dues & Licenses is the live licensing account (sweep 2026-08-13)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active AND debit_account_code = '6715';

-- ---------- 4. Same-class sweep: rules scoped to deleted source codes ----------
-- Each of these names the account in its own title, so the live code is certain.
UPDATE gl_classification_rules
SET match_source_account = '1011', updated_at = NOW(),
    override_reason = 'Source scope repaired COA-006 -> 1011 (PSS US Bank Expenses 4335) (sweep 2026-08-13)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active AND match_source_account = 'COA-006';

UPDATE gl_classification_rules
SET match_source_account = '2140', updated_at = NOW(),
    override_reason = 'Source scope repaired COA-PN-CC-1247 -> 2140 (PaperNewt Citi 1247) (sweep 2026-08-13)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active AND match_source_account = 'COA-PN-CC-1247';

UPDATE gl_classification_rules
SET match_source_account = '2171', updated_at = NOW(),
    override_reason = 'Source scope repaired COA-PERSONAL-CC-3208 -> 2171 (Personal Discover 3208) (sweep 2026-08-13)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active AND match_source_account = 'COA-PERSONAL-CC-3208';

-- NOT repaired on purpose: "Bank fees & charges" is scoped to 'COA-024', which
-- names no account and cannot be inferred from the rule. Left for Peter's call.
