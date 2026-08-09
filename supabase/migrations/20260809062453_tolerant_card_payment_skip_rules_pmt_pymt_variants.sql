-- Superseded within minutes by 20260809062606, which corrected \b to \y. Kept in the mirror
-- so a fresh `supabase db reset` replays production history in order. The two rules created
-- here are deleted by name in that later migration.
--
-- Third instance today of the same failure class: a credit-card payment reaching an
-- Unclassified account because the existing rule's wording was too literal.
--   'CAPITAL ONE - ONLINE PMT'  ($2,300, debit, personal checking -> Capital One card)
-- missed both existing Capital One rules: one requires the prefix 'Electronic Withdrawal
-- To', the other spells the abbreviation 'PYMT' where the bank wrote 'PMT'.

INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'Capital One card payment from bank (tolerant PMT/PYMT/PAYMENT)',
   20,
   '(?i)capital\s*one\b.{0,20}?\b(online|mobile|web|internet)?\W*\b(pmt|pymt|payment)\b',
   'debit', '2172', '__SOURCE__', 'high', 'manual', TRUE),
  ('126794dd-25ff-47d2-a436-724499733365',
   'SKIP — payment received onto a card (tolerant PMT/PYMT/PAYMENT)',
   20,
   '(?i)\b(online|mobile|web|internet|electronic)\W*(banking\W*)?(pmt|pymt|payment)\b|\b(pmt|pymt|payment)\W*(thank\s*you)\b',
   'credit', '__SKIP__', '__SKIP__', 'high', 'manual', TRUE);
