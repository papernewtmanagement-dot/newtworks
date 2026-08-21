-- Task 3: Insert books_historical sub-accounts under their respective parents.
-- Source: parsed SPLIT labels from legacy_import_staging.description (4,986 rows).
-- All rows scoped to chart_namespace='books_historical'. account_type inherited from parent.

DO $$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_admin_id uuid;
  v_team_id uuid;
  v_marketing_id uuid;
  v_disc_id uuid;
  v_personal_id uuid;
  v_vehicles_id uuid;
  v_sf_id uuid;
  v_admin_type text;
  v_team_type text;
  v_marketing_type text;
  v_disc_type text;
  v_personal_type text;
  v_vehicles_type text;
  v_sf_type text;
  v_inserted int := 0;
BEGIN
  SELECT id, account_type INTO v_admin_id, v_admin_type
    FROM chart_of_accounts WHERE chart_namespace = 'books_historical' AND account_name = '0001 ADMINISTRATION 6% > 5%> 5%';
  SELECT id, account_type INTO v_team_id, v_team_type
    FROM chart_of_accounts WHERE chart_namespace = 'books_historical' AND account_name = '0002 TEAM 55% > 54%> 50%';
  SELECT id, account_type INTO v_marketing_id, v_marketing_type
    FROM chart_of_accounts WHERE chart_namespace = 'books_historical' AND account_name = '0003 MARKETING 10% > 9% > 8%';
  SELECT id, account_type INTO v_disc_id, v_disc_type
    FROM chart_of_accounts WHERE chart_namespace = 'books_historical' AND account_name = '0004 DISCRETIONARY 7% > 9% > 12%';
  SELECT id, account_type INTO v_personal_id, v_personal_type
    FROM chart_of_accounts WHERE chart_namespace = 'books_historical' AND account_name = '0005 PERSONAL 22% > 23% > 25%';
  SELECT id, account_type INTO v_vehicles_id, v_vehicles_type
    FROM chart_of_accounts WHERE chart_namespace = 'books_historical' AND account_name = '0007 VEHICLES';
  SELECT id, account_type INTO v_sf_id, v_sf_type
    FROM chart_of_accounts WHERE chart_namespace = 'books_historical' AND account_name = '4005 State Farm';

  IF v_admin_id IS NULL OR v_team_id IS NULL OR v_marketing_id IS NULL
     OR v_disc_id IS NULL OR v_personal_id IS NULL OR v_vehicles_id IS NULL
     OR v_sf_id IS NULL THEN
    RAISE EXCEPTION 'Parent account lookup failed. Aborting.';
  END IF;

  CREATE TEMP TABLE tmp_subaccounts (
    parent_id uuid,
    parent_type text,
    sub_name text,
    occurrences int
  ) ON COMMIT DROP;

  -- 0001 ADMINISTRATION sub-accounts (24)
  INSERT INTO tmp_subaccounts VALUES
    (v_admin_id, v_admin_type, 'Office Supplies', 186),
    (v_admin_id, v_admin_type, 'Meals (50%)', 153),
    (v_admin_id, v_admin_type, 'Books, Subscriptions etc', 57),
    (v_admin_id, v_admin_type, 'Office Furniture & Decor', 38),
    (v_admin_id, v_admin_type, 'Business Travel', 37),
    (v_admin_id, v_admin_type, 'Building Maintenance', 36),
    (v_admin_id, v_admin_type, 'Equipment Purchases', 34),
    (v_admin_id, v_admin_type, 'Miscellaneous', 34),
    (v_admin_id, v_admin_type, 'Computer', 30),
    (v_admin_id, v_admin_type, 'Bank Charges & Fees', 23),
    (v_admin_id, v_admin_type, 'Legal & Accounting', 22),
    (v_admin_id, v_admin_type, 'Rent & Lease', 16),
    (v_admin_id, v_admin_type, 'Training, Seminars - AGENT', 14),
    (v_admin_id, v_admin_type, 'Internet', 13),
    (v_admin_id, v_admin_type, 'Cell Phone', 12),
    (v_admin_id, v_admin_type, 'Security', 6),
    (v_admin_id, v_admin_type, 'Insurance', 5),
    (v_admin_id, v_admin_type, 'Dues & Licenses - AGENT', 3),
    (v_admin_id, v_admin_type, 'Federal Income tax', 2),
    (v_admin_id, v_admin_type, 'Continuing Education', 2),
    (v_admin_id, v_admin_type, 'Legal & Financial', 1),
    (v_admin_id, v_admin_type, 'Errors & Omissions', 1),
    (v_admin_id, v_admin_type, 'Office Expense', 1),
    (v_admin_id, v_admin_type, 'Promotional Materials', 1);

  -- 0002 TEAM sub-accounts (10)
  INSERT INTO tmp_subaccounts VALUES
    (v_team_id, v_team_type, 'Payroll Costs', 130),
    (v_team_id, v_team_type, 'Employee Relations', 113),
    (v_team_id, v_team_type, 'Health Insurance Employees', 45),
    (v_team_id, v_team_type, 'Recruitment Costs', 42),
    (v_team_id, v_team_type, 'Employee Benefits', 34),
    (v_team_id, v_team_type, 'Employee Meals (50%)', 30),
    (v_team_id, v_team_type, 'Training, Seminars - TEAM', 24),
    (v_team_id, v_team_type, 'Dues & Licenses - TEAM', 5),
    (v_team_id, v_team_type, 'Special Clothing', 5),
    (v_team_id, v_team_type, 'Business Travel', 4);

  -- 0003 MARKETING sub-accounts (9)
  INSERT INTO tmp_subaccounts VALUES
    (v_marketing_id, v_marketing_type, 'Internet Leads', 151),
    (v_marketing_id, v_marketing_type, 'Ad Space', 42),
    (v_marketing_id, v_marketing_type, 'Events', 41),
    (v_marketing_id, v_marketing_type, 'Online Ads', 18),
    (v_marketing_id, v_marketing_type, 'Photography Costs', 11),
    (v_marketing_id, v_marketing_type, 'Sponsorships', 6),
    (v_marketing_id, v_marketing_type, 'Direct Mail & Supplies', 5),
    (v_marketing_id, v_marketing_type, 'Gifts, Flowers etc', 4),
    (v_marketing_id, v_marketing_type, 'Promotional Materials', 1);

  -- 0004 DISCRETIONARY sub-accounts (15)
  INSERT INTO tmp_subaccounts VALUES
    (v_disc_id, v_disc_type, 'Office Supplies', 71),
    (v_disc_id, v_disc_type, 'Meals (50%)', 33),
    (v_disc_id, v_disc_type, 'Employee Relations', 32),
    (v_disc_id, v_disc_type, 'Office Expense', 21),
    (v_disc_id, v_disc_type, 'Office Furniture & Decor', 20),
    (v_disc_id, v_disc_type, 'Events 003D', 19),
    (v_disc_id, v_disc_type, 'Building Maintenance', 15),
    (v_disc_id, v_disc_type, 'Business Travel', 15),
    (v_disc_id, v_disc_type, 'Gas, Oil, Lube', 11),
    (v_disc_id, v_disc_type, 'Equipment Purchases', 9),
    (v_disc_id, v_disc_type, 'Networking Events', 4),
    (v_disc_id, v_disc_type, 'Photography Costs', 2),
    (v_disc_id, v_disc_type, 'Vehicle Maintenance', 1),
    (v_disc_id, v_disc_type, 'Computer', 1),
    (v_disc_id, v_disc_type, 'Security', 1);

  -- 0005 PERSONAL sub-accounts (8)
  INSERT INTO tmp_subaccounts VALUES
    (v_personal_id, v_personal_type, 'Home Office Security', 19),
    (v_personal_id, v_personal_type, 'Home Office Internet', 16),
    (v_personal_id, v_personal_type, 'Ghost Tithe', 7),
    (v_personal_id, v_personal_type, 'Cell phone', 5),
    (v_personal_id, v_personal_type, 'GP Exp Leslie', 4),
    (v_personal_id, v_personal_type, 'Employee Benefits', 4),
    (v_personal_id, v_personal_type, 'Ghost Tithe SC/AIPP', 2),
    (v_personal_id, v_personal_type, 'Business Travel', 1);

  -- 0007 VEHICLES sub-accounts (4)
  INSERT INTO tmp_subaccounts VALUES
    (v_vehicles_id, v_vehicles_type, 'Gas, Oil, Lube', 20),
    (v_vehicles_id, v_vehicles_type, 'Vehicle Maintenance', 9),
    (v_vehicles_id, v_vehicles_type, 'Vehicle Registration', 2),
    (v_vehicles_id, v_vehicles_type, 'Vehicle Peter Insurance', 1);

  -- 4005 State Farm sub-accounts (11) - playbook's numbered names
  INSERT INTO tmp_subaccounts VALUES
    (v_sf_id, v_sf_type, '01 - P&C - NEW', 213),
    (v_sf_id, v_sf_type, '01 - P&C - RENEWAL', 228),
    (v_sf_id, v_sf_type, '02 - LIFE - NEW', 42),
    (v_sf_id, v_sf_type, '02 - LIFE - RENEWAL', 65),
    (v_sf_id, v_sf_type, '03 - US BANK', 18),
    (v_sf_id, v_sf_type, '04 - HEALTH - NEW', 28),
    (v_sf_id, v_sf_type, '04 - HEALTH - RENEWAL', 8),
    (v_sf_id, v_sf_type, '05 - PET INSURANCE - NEW', 0),
    (v_sf_id, v_sf_type, '05 - PET INSURANCE - RENEWAL', 0),
    (v_sf_id, v_sf_type, '06 - SFVC', 37),
    (v_sf_id, v_sf_type, '07 - IPSI LIFE', 22);

  -- Insert into chart_of_accounts; provenance + occurrence count goes in account_subtype
  INSERT INTO chart_of_accounts (
    agency_id, chart_namespace, account_code, account_name, account_type,
    account_subtype, parent_account_id, is_active, is_system, created_at
  )
  SELECT
    v_agency_id,
    'books_historical',
    'COA-SUB-' || LPAD(ROW_NUMBER() OVER (ORDER BY parent_id, sub_name)::text, 3, '0'),
    sub_name,
    parent_type,
    'task3_split_label/occ=' || occurrences,
    parent_id,
    true,
    false,
    NOW()
  FROM tmp_subaccounts;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RAISE NOTICE 'Inserted % books_historical sub-accounts', v_inserted;
END $$;
