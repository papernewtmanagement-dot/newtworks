-- Chase card payments have NEVER had a rule. Seven of them, $24,598.62, sat in
-- *Unclassified Expense — Business, inflating agency expenses. Four were exposed by the
-- 2026-08-09 re-parse of the 4335 January-May statements; three predate it.
--
-- Same class as the Capital One and U.S. Bank payment rules added earlier today: money leaving
-- a bank account to pay a card is a payment leg, not spending. Target is the Chase Marketing
-- card's own liability account (2110), which the balance-sheet guard turns into a clean skip.
--
-- Verified against the live description corpus before applying: matches only
-- 'Electronic Withdrawal To CHASE CREDIT CRD' and 'CHASE CREDIT CRD — REF=...', and does NOT
-- match the SA WATER SYSTEM rows, which contain the letters 'chase' inside 'PURCHASE'.
-- Requiring the words 'credit crd' is what makes that safe; a bare 'chase' match would not be.

INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'Chase card payment from bank -> Chase Marketing card',
   20,
   '(?i)chase\s+credit\s+crd',
   'debit', '2110', '__SOURCE__', 'high', 'manual', TRUE);
