-- Peter 2026-09-26 (third batch). Dart Armoury waits on a Personal "Gifts & Presents" account
-- (chart of accounts is locked to Peter's explicit approval).
DO $$
DECLARE a uuid := '126794dd-25ff-47d2-a436-724499733365';
  pn uuid := 'b1111111-1111-1111-1111-111111111111';
  ag uuid := 'b2222222-2222-2222-2222-222222222222';
  n int;
BEGIN
  -- Rover is a pet thing: same treatment as PetSmart / Don's (PaperNewt Advertising, mascot photography).
  UPDATE gl_classification_rules SET rule_name='Rover -> PN Advertising (mascot photography)', match_payee_regex='(?i)ROVER\.COM',
    match_priority=50, match_direction='both', debit_account_code='6400', credit_account_code='6400',
    target_business_entity_id=pn, is_active=true, source='peter_2026-09-26', updated_at=now()
   WHERE id='b3463791-1e1f-4b49-884a-dcacb21651e1';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'rover: %', n; END IF;

  INSERT INTO gl_classification_rules
    (agency_id, rule_name, match_priority, match_payee_regex, match_source_account, match_direction,
     debit_account_code, credit_account_code, target_business_entity_id, rule_scope, source, is_active, confidence)
  VALUES
    -- Priority 3 beats the AMEX restaurant rule (6), which had been sending TMAD to PaperNewt meals.
    (a, 'TMAD -> Agency Employee Relations (any card)', 3, '(?i)\yTMAD\y', NULL, 'both', '6160', '6160', ag, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'TV (card alert, no store name) -> PN Office Supplies (waiting room)', 50, '(?i)^\s*TV\s*$', NULL, 'both', '6910', '6910', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Florida Department of Revenue -> Agency Payroll Taxes (unemployment tax)', 50, '(?i)FLA\.?\s*DEPT\.?\s*(OF\s*)?REVENUE|FLORIDA\s*DEP(ARTMEN)?T\.?\s*(OF\s*)?REVENUE', NULL, 'both', '6030', '6030', ag, 'both', 'peter_2026-09-26', true, 'high');
END $$;
