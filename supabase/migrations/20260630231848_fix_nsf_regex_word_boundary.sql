-- Fix NSF / Overdraft regex: previous `NSF|OVERDRAFT` matched "TRANSFER" because
-- "TRANSFER" contains the substring "NSF". This caused all inter-account transfers
-- to be wrongly classified as bank fees. Adding word boundaries.
UPDATE public.gl_classification_rules
SET match_payee_regex = '\yNSF\y|\yOVERDRAFT\y'
WHERE id = 'bc567ce7-a762-40e3-92e6-97697165e6ae'
  AND rule_name = 'MINED: NSF / Overdraft';
