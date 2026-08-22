-- P&L income section reorganization (Peter directive 2026-07-17):
--   1. Rename Income section "root" -> "External" (scope: section_type='Income' only;
--      Expense/Other Income "root" buckets stay untouched)
--   2. Create new Income parent "Alliances", move 03 US Bank + 05 Pet Insurance (New+Renewal) under it
--   3. Create new Income parent "IPS", move 07 IPSI Life + 06 SFVC under it
--
-- Applies to both display drivers:
--   - prior_year_pl.section  (drives pre-cutover P&L rows)
--   - chart_of_accounts parent chain in historical namespace (drives post-cutover
--     journal_entries rows via get_pnl_history COA walk)

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_entity uuid := 'b1111111-1111-1111-1111-111111111111';
  v_alliances_id uuid;
  v_ips_id uuid;
  v_external_id uuid;
BEGIN
  -- Alliances parent
  SELECT id INTO v_alliances_id FROM chart_of_accounts
  WHERE agency_id=v_agency AND account_name='Alliances' AND account_type='income' AND chart_namespace='historical';
  IF v_alliances_id IS NULL THEN
    INSERT INTO chart_of_accounts (agency_id, business_entity_id, account_code, account_name, account_type, parent_account_id, is_active, is_system, chart_namespace)
    VALUES (v_agency, v_entity, 'COA-033', 'Alliances', 'income', NULL, true, false, 'historical')
    RETURNING id INTO v_alliances_id;
  END IF;

  -- IPS parent
  SELECT id INTO v_ips_id FROM chart_of_accounts
  WHERE agency_id=v_agency AND account_name='IPS' AND account_type='income' AND chart_namespace='historical';
  IF v_ips_id IS NULL THEN
    INSERT INTO chart_of_accounts (agency_id, business_entity_id, account_code, account_name, account_type, parent_account_id, is_active, is_system, chart_namespace)
    VALUES (v_agency, v_entity, 'COA-034', 'IPS', 'income', NULL, true, false, 'historical')
    RETURNING id INTO v_ips_id;
  END IF;

  -- External parent (rehomes the current "root" income accounts)
  SELECT id INTO v_external_id FROM chart_of_accounts
  WHERE agency_id=v_agency AND account_name='External' AND account_type='income' AND chart_namespace='historical';
  IF v_external_id IS NULL THEN
    INSERT INTO chart_of_accounts (agency_id, business_entity_id, account_code, account_name, account_type, parent_account_id, is_active, is_system, chart_namespace)
    VALUES (v_agency, v_entity, 'COA-035', 'External', 'income', NULL, true, false, 'historical')
    RETURNING id INTO v_external_id;
  END IF;

  -- Reparent COA sub-accounts under new parents
  UPDATE chart_of_accounts SET parent_account_id = v_alliances_id
  WHERE agency_id=v_agency AND chart_namespace='historical'
    AND account_name IN ('03 - US BANK', '05 - PET INSURANCE - NEW', '05 - PET INSURANCE - RENEWAL');

  UPDATE chart_of_accounts SET parent_account_id = v_ips_id
  WHERE agency_id=v_agency AND chart_namespace='historical'
    AND account_name IN ('07 - IPSI LIFE', '06 - SFVC');

  -- Reparent the two historical "root" income accounts that exist in COA under External.
  -- (4055 Interest Income + Quicken Loans exist only in prior_year_pl, not COA - nothing to reparent there.)
  UPDATE chart_of_accounts SET parent_account_id = v_external_id
  WHERE agency_id=v_agency AND chart_namespace='historical' AND account_type='income'
    AND account_name IN ('4025 NFIP', 'Gainsco');
END $$;

-- prior_year_pl.section rewrites (drives what shows in the P&L today for historical periods)
UPDATE public.prior_year_pl SET section = 'External'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND section='root'
  AND section_type='Income';

UPDATE public.prior_year_pl SET section = 'Alliances'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND account_name IN ('03 - US BANK', '05 - PET INSURANCE - NEW', '05 - PET INSURANCE - RENEWAL');

UPDATE public.prior_year_pl SET section = 'IPS'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND account_name IN ('07 - IPSI LIFE', '06 - SFVC');
