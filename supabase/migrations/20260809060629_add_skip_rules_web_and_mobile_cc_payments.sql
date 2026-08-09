-- Two credit-card payment descriptions reached *Unclassified Income on 2026-08-09
-- because existing rules missed them:
--   'Payment Thank You - Web'   -> existing rule regex is end-anchored '^PAYMENT\s+THANK\s+YOU$'
--   'CAPITAL ONE MOBILE PYMT'   -> existing rule covers ONLINE PYMT only
-- Both are payments onto a card, not income. Added as __SKIP__ rules, matching the
-- existing 'SKIP — credit card payment legs' family, rather than routing to 3090
-- Internal Transfers, which is scoped to personal accounts (the Chase card is agency).

INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'SKIP — CC payment received (Thank You, Web variant)',
   1,
   '(?i)payment\s*[-–—]?\s*thank\s+you\s*[-–—]\s*web',
   'credit', '__SKIP__', '__SKIP__', 'high', 'manual', TRUE),
  ('126794dd-25ff-47d2-a436-724499733365',
   'SKIP — CC payment received (Capital One mobile)',
   1,
   '(?i)capital\s+one\s+mobile\s+pymt',
   'credit', '__SKIP__', '__SKIP__', 'high', 'manual', TRUE);
