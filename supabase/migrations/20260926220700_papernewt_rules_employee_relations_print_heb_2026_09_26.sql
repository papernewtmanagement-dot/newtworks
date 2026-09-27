-- Peter 2026-09-26: PaperNewt classifications for charges that sat in Unclassified.
-- Priority: lower number wins (writers sort match_priority ASC).
DO $$
DECLARE a uuid := '126794dd-25ff-47d2-a436-724499733365';
        pn uuid := 'b1111111-1111-1111-1111-111111111111';
        n int;
BEGIN
  -- HEB: card receipts arrive as "H E B 108" (spaces). Existing rules only knew H-E-B / HEB.
  UPDATE gl_classification_rules SET match_payee_regex = '(?i)\yH[- ]?E[- ]?B\y', updated_at = now()
   WHERE agency_id = a AND match_payee_regex = '(?i)H-E-B|HEB\y';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n < 7 THEN RAISE EXCEPTION 'expected >= 7 HEB rules updated, got %', n; END IF;
  UPDATE gl_classification_rules SET match_payee_regex = '(?i)\yH[- ]?E[- ]?B\s*(FUEL|GAS)', updated_at = now()
   WHERE id = 'a57fce3b-deaa-4b8b-8b1c-b4ee12101af8';

  -- Citi 1247 print costs: newer statements read the payee as bare "ND4C" (no "HOUSTON").
  UPDATE gl_classification_rules
     SET match_payee_regex = '(?i)\yND4C\y', rule_name = 'ND4C -> PN Print COGS (Citi 1247)', updated_at = now()
   WHERE id = 'd8b60bd5-93c7-4239-aa72-151db254c646';

  INSERT INTO gl_classification_rules
    (agency_id, rule_name, match_priority, match_payee_regex, match_source_account, match_direction,
     debit_account_code, credit_account_code, target_business_entity_id, rule_scope, source, is_active, confidence)
  VALUES
    (a, '4over -> PN Print COGS (Citi 1247)', 110, '(?i)4\s*OVER', '2140', 'both', '5100', '5100', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Citi 1247 printing card — any other charge -> PN Print COGS', 200, NULL, '2140', 'debit', '5100', '__SOURCE__', pn, 'both', 'peter_2026-09-26', true, 'medium'),
    -- Employee relations (PaperNewt 6160)
    (a, 'Parry''s Pizza -> PN Employee Relations', 50, '(?i)PARRY''?S\s*PIZZA', NULL, 'both', '6160', '6160', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Izumi -> PN Employee Relations', 50, '(?i)\yIZUMI\y', NULL, 'both', '6160', '6160', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Coffee Crush -> PN Employee Relations', 50, '(?i)COFFEE\s*CRUSH', NULL, 'both', '6160', '6160', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Mister Softee -> PN Employee Relations', 50, '(?i)MI?STE?R\.?\s*SOFTEE', NULL, 'both', '6160', '6160', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Raid Shadow Legends -> PN Employee Relations', 50, '(?i)RAID\s*SHADOW|PLARIUM', NULL, 'both', '6160', '6160', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Tastea Boba -> PN Employee Relations', 50, '(?i)TASTEA', NULL, 'both', '6160', '6160', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'PlayStation -> PN Employee Relations (any card)', 50, '(?i)PLAYSTATION', NULL, 'both', '6160', '6160', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Alamo Drafthouse on Capital One Personal 2172 -> PN Employee Relations', 50, '(?i)ALAMO\s*DR\w*TH', '2172', 'both', '6160', '6160', pn, 'both', 'peter_2026-09-26', true, 'high'),
    (a, 'Alamo Drafthouse (any other card) -> Employee Relations of the card''s business', 60, '(?i)ALAMO\s*DR\w*TH', NULL, 'both', '6160', '6160', NULL, 'both', 'peter_2026-09-26', true, 'high'),
    -- Stress relief -> PaperNewt Employee Benefits
    (a, 'Snailax (stress relief) -> PN Employee Benefits', 50, '(?i)SNAILAX', NULL, 'both', '6110', '6110', pn, 'both', 'peter_2026-09-26', true, 'high'),
    -- Pest control -> PaperNewt Repairs & Maintenance
    (a, 'Do My Own (pest control) -> PN Repairs & Maintenance', 50, '(?i)DO\s*MY\s*OWN|DOMYOWN', NULL, 'both', '6240', '6240', pn, 'both', 'peter_2026-09-26', true, 'high');
END $$;
