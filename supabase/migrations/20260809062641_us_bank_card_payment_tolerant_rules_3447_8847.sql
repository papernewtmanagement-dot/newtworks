-- Last two card payments still landing in an Unclassified account: U.S. Bank web payments
-- onto cards 3447 and 8847 ($4,704.08 and $536.48). Existing rules require the literal
-- 'U.S. BANK WEB PYMT 8847' or 'Mobile Banking Payment To Credit Card 8847'; these rows carry
-- an em-dash separator, a REF block, and masked digits, so neither matched.
--
-- Verified against the live description corpus before applying: each pattern matches only its
-- own card's payment rows and nothing else. The bare 'Credit Card — ****3447' descriptions are
-- deliberately left alone - they are already handled by the existing internal-transfer rules.
-- Targets are the cards' own liability accounts (2113, 2173), which the balance-sheet guard
-- turns into clean skips - the established house pattern for a payment leg.

INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'US Bank card payment from bank -> card 3447 (tolerant)',
   20,
   '(?i)u\.?\s*s\.?\s*bank\y.{0,80}?(web|online|mobile)\s*(banking\s*)?(pymt|pmt|payment)\D{0,15}3447',
   'debit', '2113', '__SOURCE__', 'high', 'manual', TRUE),
  ('126794dd-25ff-47d2-a436-724499733365',
   'US Bank card payment from bank -> card 8847 (tolerant)',
   20,
   '(?i)u\.?\s*s\.?\s*bank\y.{0,80}?(web|online|mobile)\s*(banking\s*)?(pymt|pmt|payment)\D{0,15}8847',
   'debit', '2173', '__SOURCE__', 'high', 'manual', TRUE);
