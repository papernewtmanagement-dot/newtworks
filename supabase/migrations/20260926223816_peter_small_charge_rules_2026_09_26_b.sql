-- Peter 2026-09-26 (second batch). Old inactive rules pointed at 9800 Discretionary, which no longer
-- exists; they are amended in place and switched on rather than duplicated.
DO $$
DECLARE a uuid := '126794dd-25ff-47d2-a436-724499733365';
  pn uuid := 'b1111111-1111-1111-1111-111111111111';
  ag uuid := 'b2222222-2222-2222-2222-222222222222';
  pe uuid := 'b3333333-3333-3333-3333-333333333333';
  n int;
BEGIN
  -- YouTube: always PaperNewt Software, any card. Beats the AMEX Google rule (priority 5).
  UPDATE gl_classification_rules SET rule_name='YouTube -> PN Software (any card)', match_payee_regex='(?i)YOUTUBE',
    match_priority=4, match_direction='both', debit_account_code='6310', credit_account_code='6310',
    target_business_entity_id=pn, is_active=true, source='peter_2026-09-26', updated_at=now()
   WHERE agency_id=a AND rule_name='Google YouTube / Play — Personal Discretionary';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'youtube: %', n; END IF;

  -- Pet things + nail bar: mascot photography / advertising -> PaperNewt Advertising & Marketing.
  UPDATE gl_classification_rules SET rule_name = replace(rule_name, '-> Discretionary', '-> PN Advertising (mascot photography)'),
    match_priority=50, match_direction='both', debit_account_code='6400', credit_account_code='6400',
    target_business_entity_id=pn, is_active=true, source='peter_2026-09-26', updated_at=now()
   WHERE agency_id=a AND rule_name IN ('PetSmart -> Discretionary','Dons Tropical Pets -> Discretionary','Hyatt Nail Bar -> Discretionary');
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 3 THEN RAISE EXCEPTION 'pet/nail: %', n; END IF;
  UPDATE gl_classification_rules SET match_payee_regex='(?i)DONS\s*TROPICAL\s*PETS'
   WHERE agency_id=a AND rule_name LIKE 'Dons Tropical Pets -> PN Advertising%';

  -- Office decor / supplies -> PaperNewt Office Supplies & Expense (there is no separate decor account).
  UPDATE gl_classification_rules SET rule_name='Photoprint -> PN Office Supplies (office decor)',
    match_priority=50, match_direction='both', debit_account_code='6910', credit_account_code='6910',
    target_business_entity_id=pn, is_active=true, source='peter_2026-09-26', updated_at=now()
   WHERE agency_id=a AND rule_name='Photoprint Online -> Discretionary';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'photoprint: %', n; END IF;

  -- Personal health -> Personal Medical & Health.
  UPDATE gl_classification_rules SET rule_name = replace(rule_name, '-> Discretionary', '-> Personal Medical & Health'),
    match_priority=50, match_direction='both', debit_account_code='9500', credit_account_code='9500',
    target_business_entity_id=pe, is_active=true, source='peter_2026-09-26', updated_at=now()
   WHERE agency_id=a AND rule_name IN ('1 Natural Way -> Discretionary','SP Lymphoria -> Discretionary','Pure Mana CBD -> Discretionary',
                                      'Moonwlkr -> Discretionary','Charlottes Web -> Discretionary','Movement Mentorship -> Discretionary');
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 6 THEN RAISE EXCEPTION 'health: %', n; END IF;
  UPDATE gl_classification_rules SET match_payee_regex='(?i)MOVEMENT\s*MENTORSHIP' WHERE agency_id=a AND rule_name LIKE 'Movement Mentorship -> Personal%';
  UPDATE gl_classification_rules SET match_payee_regex='(?i)CHARLOTTE''?S\s*WEB' WHERE agency_id=a AND rule_name LIKE 'Charlottes Web -> Personal%';
  UPDATE gl_classification_rules SET match_payee_regex='(?i)\y1\s*NATURAL\s*WAY' WHERE agency_id=a AND rule_name LIKE '1 Natural Way -> Personal%';
  UPDATE gl_classification_rules SET match_payee_regex='(?i)PURE\s*MANA' WHERE agency_id=a AND rule_name LIKE 'Pure Mana CBD -> Personal%';

  -- New rules where none existed.
  INSERT INTO gl_classification_rules
    (agency_id, rule_name, match_priority, match_payee_regex, match_source_account, match_direction,
     debit_account_code, credit_account_code, target_business_entity_id, rule_scope, source, is_active, confidence)
  VALUES
    (a, 'UPS Store (office keys) -> Agency Office Supplies & Expense', 50, '(?i)\yUPS\s*STORE', NULL, 'both', '6910', '6910', ag, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Buddy''s Toys -> PN Office Supplies (office decor)', 50, '(?i)BUDDY''?S\s*TOYS', NULL, 'both', '6910', '6910', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Walmart -> PN Office Supplies (any card; Walmart Grocery rule still wins)', 60, '(?i)WAL-?\s*MART', NULL, 'both', '6910', '6910', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Old Navy -> Personal Clothing', 50, '(?i)OLD\s*NAVY', NULL, 'both', '9250', '9250', pe, 'both', 'peter_2026-09-26', true, 'high');
END $$;
