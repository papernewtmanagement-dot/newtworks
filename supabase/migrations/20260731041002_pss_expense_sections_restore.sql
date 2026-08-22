-- Restore 5 P&L expense sections on PSS via section_label_override
-- Peter directive 2026-07-31: sections = Admin, Growth, Team, Marketing, Personal.
-- Growth is tag-driven (routed in get_pnl_history fns below). Other 4 are
-- account-driven via section_label_override.

DO $mig$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pss_entity uuid;
BEGIN
  SELECT id INTO v_pss_entity FROM business_entities
    WHERE agency_id = v_agency AND slug = 'pss';

  -- Admin: occupancy, tech, professional, insurance, G&A, ex-Discretionary (vehicle/travel/meals)
  UPDATE chart_of_accounts SET section_label_override = 'Admin'
   WHERE agency_id = v_agency AND business_entity_id = v_pss_entity
     AND account_code IN (
       '6210','6220','6240','6250','6270','6280',      -- occupancy
       '6310','6320','6330',                            -- tech
       '6510','6520','6530',                            -- professional
       '6610','6620',                                   -- insurance
       '6810','6850','6860',                            -- ex-Discretionary: vehicle, travel, meals
       '6910','6940','6941','6945','6950','6960'        -- G&A
     );

  -- Team: payroll, benefits, ed & licensing
  UPDATE chart_of_accounts SET section_label_override = 'Team'
   WHERE agency_id = v_agency AND business_entity_id = v_pss_entity
     AND account_code IN (
       '6010','6020','6030','6060',                     -- payroll
       '6110','6115','6120','6160','6180',              -- benefits
       '6710','6720','6740','6750'                      -- ed & licensing
     );

  -- Marketing: advertising, digital, website
  UPDATE chart_of_accounts SET section_label_override = 'Marketing'
   WHERE agency_id = v_agency AND business_entity_id = v_pss_entity
     AND account_code IN ('6400','6410','6470');

  -- Suspense: leave 0003 NULL (INITCAP fallback renders as "Suspense")
  UPDATE chart_of_accounts SET section_label_override = NULL
   WHERE agency_id = v_agency AND business_entity_id = v_pss_entity
     AND account_code = '0003';
END $mig$;
