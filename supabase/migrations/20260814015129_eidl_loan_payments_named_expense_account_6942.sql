-- Peter directive 2026-08-13, explicit approval given to add the account and
-- relock the tables afterward.
--
-- EIDL payments are an expense to the business, per Peter. No below-the-line
-- section, no debt schedule, no second bottom line. The only change is moving
-- them out of the unclassified suspense bucket into a named account so the
-- figure is visible and identifiable at tax time.
--
-- chart_of_accounts and account_master_codes are guarded by
-- block_chart_of_accounts_writes(). Approved procedure is: drop the lock, make
-- the change, recreate the lock. Both triggers are recreated at the end of this
-- migration, in the same transaction, so the tables are never left unlocked.

DROP TRIGGER IF EXISTS lock_chart_of_accounts ON public.chart_of_accounts;
DROP TRIGGER IF EXISTS lock_account_master_codes ON public.account_master_codes;

-- chart_of_accounts.account_code has a foreign key to account_master_codes(code),
-- so the master code has to exist first. Entity-specific because this account
-- belongs to PaperNewt alone, which also means the rule targeting 6942 resolves
-- to PaperNewt no matter which card paid.
INSERT INTO account_master_codes (
  agency_id, code, name, account_type, account_subtype, code_kind, description
)
SELECT '126794dd-25ff-47d2-a436-724499733365', '6942', 'EIDL Loan Payments',
       'expense', 'debt_service', 'entity_specific',
       'SBA EIDL loan payments. Cash cost to the business. NOT fully tax deductible - the principal portion is not deductible, only the interest portion is. Kept as its own account so the non-deductible amount is identifiable at tax time.'
WHERE NOT EXISTS (
  SELECT 1 FROM account_master_codes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND code = '6942');

INSERT INTO chart_of_accounts (
  agency_id, business_entity_id, account_code, account_name,
  account_type, account_subtype, section_label_override, is_active
)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'b1111111-1111-1111-1111-111111111111',
       '6942', 'EIDL Loan Payments', 'expense', 'debt_service', 'Expense', TRUE
WHERE NOT EXISTS (
  SELECT 1 FROM chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND account_code = '6942'
    AND business_entity_id = 'b1111111-1111-1111-1111-111111111111');

-- Relock immediately, before any other work.
CREATE TRIGGER lock_chart_of_accounts
  BEFORE INSERT OR DELETE OR UPDATE ON public.chart_of_accounts
  FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();

CREATE TRIGGER lock_account_master_codes
  BEFORE INSERT OR DELETE OR UPDATE ON public.account_master_codes
  FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();

-- New rule pointing at the named account. The earlier rule that routed these to
-- the loan liability account stays deactivated.
INSERT INTO gl_classification_rules (
  agency_id, rule_name, match_priority, match_payee_regex, match_direction,
  debit_account_code, credit_account_code, target_business_entity_id,
  sub_category_label, confidence, source
)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid,
       'SBA EIDL loan payment — PaperNewt', 15,
       '(?i)sba\s+eidl\s+loan', 'both', '6942', '__SOURCE__',
       'b1111111-1111-1111-1111-111111111111',
       'EIDL loan payment', 'high', 'peter_directive_20260813'
WHERE NOT EXISTS (
  SELECT 1 FROM gl_classification_rules
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND rule_name = 'SBA EIDL loan payment — PaperNewt');

-- Move the existing payments out of suspense into the named account. In-place
-- reclassification, no ledger rows removed.
UPDATE ledger l
SET account_id = (SELECT id FROM chart_of_accounts
                  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
                    AND account_code = '6942'
                    AND business_entity_id = 'b1111111-1111-1111-1111-111111111111'),
    rule_id_used = (SELECT id FROM gl_classification_rules
                    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
                      AND rule_name = 'SBA EIDL loan payment — PaperNewt'),
    classification_status = 'classified',
    classified_by = 'rule:' || (SELECT id::text FROM gl_classification_rules
                    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
                      AND rule_name = 'SBA EIDL loan payment — PaperNewt'),
    classified_at = NOW()
WHERE l.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND l.description ~* 'sba\s+eidl\s+loan';
