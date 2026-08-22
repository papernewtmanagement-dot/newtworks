DO $mig$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pn_entity uuid;
  v_pn_0003 uuid;
  v_pn_3050 uuid;
  v_reclass_id uuid;
  v_row_count int;
  v_total numeric;
BEGIN
  SELECT id INTO v_pn_entity FROM business_entities
    WHERE agency_id = v_agency AND slug = 'papernewt';
  IF v_pn_entity IS NULL THEN RAISE EXCEPTION 'PN entity not found'; END IF;

  SELECT id INTO v_pn_0003 FROM chart_of_accounts
    WHERE agency_id = v_agency AND business_entity_id = v_pn_entity
      AND account_code = '0003' AND is_active = true;
  IF v_pn_0003 IS NULL THEN RAISE EXCEPTION 'PN 0003 not found'; END IF;

  INSERT INTO chart_of_accounts (
    agency_id, business_entity_id, account_code, account_name,
    account_type, account_subtype, is_active, section_label_override
  )
  SELECT v_agency, v_pn_entity, '3050', 'S-Corp Distributions',
         'equity', 'distribution', true, NULL
  WHERE NOT EXISTS (
    SELECT 1 FROM chart_of_accounts
    WHERE agency_id = v_agency AND business_entity_id = v_pn_entity
      AND account_code = '3050'
  );
  UPDATE chart_of_accounts
     SET is_active = true, account_name = 'S-Corp Distributions'
   WHERE agency_id = v_agency AND business_entity_id = v_pn_entity
     AND account_code = '3050';
  SELECT id INTO v_pn_3050 FROM chart_of_accounts
    WHERE agency_id = v_agency AND business_entity_id = v_pn_entity
      AND account_code = '3050';

  SELECT COUNT(*), COALESCE(SUM(debit - credit), 0)
    INTO v_row_count, v_total
    FROM journal_lines
   WHERE agency_id = v_agency AND account_id = v_pn_0003;

  INSERT INTO account_reclassifications (
    agency_id, from_account_id, to_account_id,
    from_account_code, from_account_name, from_business_entity_id,
    filter_description, journal_line_count, total_amount,
    performed_at, performed_by, notes
  ) VALUES (
    v_agency, v_pn_0003, v_pn_3050,
    '0003', '*Unclassified Expense — Business', v_pn_entity,
    'All journal_lines on PaperNewt 0003 *Unclassified Expense — Business (AMEX Discretionary card)',
    v_row_count, v_total,
    NOW(), 'claude',
    'Sweep aged PN 0003 suspense ($8,221 aged 238d) to 3050 S-Corp Distributions. '
    ||'AMEX Discretionary card (2141) is Peter''s personal-charge pipe; economically '
    ||'these are shareholder distributions, not agency expenses. Amex Cash Rebate '
    ||'credits ($250.65) net into the distribution.'
  ) RETURNING id INTO v_reclass_id;

  UPDATE journal_lines jl
     SET account_id = v_pn_3050,
         original_account_id = COALESCE(jl.original_account_id, v_pn_0003),
         original_account_code = COALESCE(jl.original_account_code, '0003'),
         original_account_name = COALESCE(jl.original_account_name, '*Unclassified Expense — Business'),
         reclassification_id = v_reclass_id
   WHERE jl.agency_id = v_agency
     AND jl.account_id = v_pn_0003;

  RAISE NOTICE 'Moved % journal_lines (net $%) from PN 0003 -> PN 3050 (reclass_id=%)',
    v_row_count, v_total, v_reclass_id;
END $mig$;
