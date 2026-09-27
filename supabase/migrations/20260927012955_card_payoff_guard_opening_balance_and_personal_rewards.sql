-- 1) Card payoff guard also recognizes a payment that matches a statement's OPENING balance
--    (the prior statement's closing), so a missing statement no longer turns a payoff into spending.
DO $$
DECLARE d text;
  old_t text := E'          AND sb.closing_balance = v_amount\n          AND sb.statement_period_end <= v_txn_date\n          AND sb.statement_period_end >= v_txn_date - 45\n';
  new_t text := E'          AND ((sb.closing_balance = v_amount\n                AND sb.statement_period_end <= v_txn_date\n                AND sb.statement_period_end >= v_txn_date - 45)\n            -- Peter 2026-09-27: the statement this pays may be missing; the next statement''s\n            -- opening balance is the same number.\n            OR (sb.opening_balance = v_amount\n                AND sb.statement_period_start - 1 <= v_txn_date\n                AND sb.statement_period_start - 1 >= v_txn_date - 45))\n';
BEGIN
  SELECT pg_get_functiondef('public.cash_register_gl_writer'::regproc) INTO d;
  IF position('opening_balance = v_amount' IN d) > 0 THEN RETURN; END IF;
  IF position(old_t IN d) = 0 THEN RAISE EXCEPTION 'card payment guard not found'; END IF;
  EXECUTE replace(d, old_t, new_t);
END $$;

-- 2) Cash-back rewards on personal cards belong to Personal (they were landing on the agency
--    or PaperNewt because the general rule has no account on the Personal side).
INSERT INTO gl_classification_rules (agency_id, rule_name, match_priority, match_payee_regex, match_source_account, match_direction,
  debit_account_code, credit_account_code, target_business_entity_id, rule_scope, source, is_active, confidence)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Cash-back reward on personal card ' || c || ' -> Personal Credit Card Rewards', 9,
       '(?i)(cash[-\s]?back\s+reward)|(credit-cash\s+back)|(your\s+cash\s+reward)', c, 'both', '9820', '9820',
       'b3333333-3333-3333-3333-333333333333', 'both', 'claude_2026-09-27', true, 'high'
FROM unnest(ARRAY['2170','2171','2172','2173']) c
WHERE NOT EXISTS (SELECT 1 FROM gl_classification_rules r WHERE r.agency_id='126794dd-25ff-47d2-a436-724499733365'
                  AND r.match_source_account = c AND r.debit_account_code='9820' AND r.match_payee_regex ~* 'cash');
