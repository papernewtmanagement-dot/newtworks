-- Two writers share one rule table but see different data. The statement writer
-- has a payee AND a memo to test. The cash register only ever has a merchant
-- name -- a bank alert carries no memo. So a rule whose ONLY condition is the
-- memo has nothing to test in the register path, its one condition silently
-- drops out, and it matches every uncoded charge that reaches it. That is how
-- the Clear Channel billboard rule became a wildcard into Advertising &
-- Marketing.
--
-- Only rules with NO payee regex are affected. Rules that match on both payee
-- and memo (employee meals, Airbnb, Vault fundraiser) still test the merchant
-- in the register path and stay scoped to 'both'.

ALTER TABLE public.gl_classification_rules
  ADD COLUMN IF NOT EXISTS rule_scope text NOT NULL DEFAULT 'both';

ALTER TABLE public.gl_classification_rules
  DROP CONSTRAINT IF EXISTS gl_classification_rules_rule_scope_check;

ALTER TABLE public.gl_classification_rules
  ADD CONSTRAINT gl_classification_rules_rule_scope_check
  CHECK (rule_scope IN ('both','statement','register'));

COMMENT ON COLUMN public.gl_classification_rules.rule_scope IS
  'Which writer may use this rule. both = either. statement = statement_gl_writer only; required for any rule whose only condition is the memo, because the cash register has no memo field. register = cash_register_gl_writer only.';

-- Memo-only rules can work on statements and nowhere else.
UPDATE public.gl_classification_rules
SET rule_scope = 'statement', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND match_memo_regex IS NOT NULL
  AND match_payee_regex IS NULL
  AND rule_scope <> 'statement';
