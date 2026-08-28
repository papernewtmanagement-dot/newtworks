-- Every row in txn_coding_rules is a June 2026 seed written against a
-- placeholder chart of accounts that was never built: 6500-Office-Supplies,
-- 6100-Payroll-Wages, 1020-USBank-4335, 4000-SF-Commission and so on. None of
-- those codes exist in chart_of_accounts, so these rules cannot ever produce a
-- valid posting -- all they do is stamp a dead account onto cash register rows
-- as a suggestion and mark them "needs your input". Only the Amazon rule has
-- ever fired (24 times, all cosmetic).
--
-- Deactivating rather than deleting: the real ledger rules in
-- gl_classification_rules already decide where Amazon and everything else
-- posts, so nothing is lost. Which account Amazon belongs to on each card is
-- Peter's call, not something to guess here.

UPDATE txn_coding_rules
SET is_active = FALSE, updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = TRUE
  AND debit_account NOT IN (SELECT account_code FROM chart_of_accounts
                            WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365');

-- Clear the dead suggestions already stamped onto open cash register rows and
-- put them back to unclassified alongside the rest.
UPDATE cash_register_preliminary
SET suggested_debit_account = NULL,
    suggested_credit_account = NULL,
    suggested_rule_id = NULL,
    suggested_confidence = NULL,
    coding_status = 'unclassified',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND coding_status = 'needs_peter'
  AND peter_coded_at IS NULL
  AND suggested_debit_account IS NOT NULL
  AND suggested_debit_account NOT IN (SELECT account_code FROM chart_of_accounts
                                      WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365');
