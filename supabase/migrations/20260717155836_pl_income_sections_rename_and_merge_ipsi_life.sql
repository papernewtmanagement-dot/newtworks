-- P&L income section polish (Peter directive 2026-07-17 followup):
--   1. Merge "07 - IPSI LIFE ALLIANCE" into "07 - IPSI LIFE" (same account, older QBO label)
--      and rename to "IPSI LIFE"
--   2. Strip numbered prefixes from Alliances + IPS child accounts:
--        03 - US BANK              -> US BANK
--        05 - PET INSURANCE - NEW  -> PET INSURANCE - NEW
--        05 - PET INSURANCE - RENEWAL -> PET INSURANCE - RENEWAL
--        06 - SFVC                 -> SFVC
--        07 - IPSI LIFE            -> IPSI LIFE
--   3. Rename parent Income sections:
--        4005 State Farm  -> State Farm
--        Alliances        -> Alliances - SF Comp
--        IPS              -> IPS - SF Comp
--   4. Update settings.gl_default_sf_revenue_account_name so SF commission ingest keeps
--      finding the renamed parent (post_sf_commission_recap resolves parent by name).

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
BEGIN
  -- COA parent renames (historical namespace)
  UPDATE chart_of_accounts SET account_name='State Farm'
  WHERE agency_id=v_agency AND account_name='4005 State Farm'
    AND account_type='income' AND chart_namespace='historical';

  UPDATE chart_of_accounts SET account_name='Alliances - SF Comp'
  WHERE agency_id=v_agency AND account_name='Alliances'
    AND account_type='income' AND chart_namespace='historical';

  UPDATE chart_of_accounts SET account_name='IPS - SF Comp'
  WHERE agency_id=v_agency AND account_name='IPS'
    AND account_type='income' AND chart_namespace='historical';

  -- COA sub-account prefix stripping (historical namespace)
  UPDATE chart_of_accounts SET account_name='US BANK'
  WHERE agency_id=v_agency AND account_name='03 - US BANK' AND chart_namespace='historical';

  UPDATE chart_of_accounts SET account_name='PET INSURANCE - NEW'
  WHERE agency_id=v_agency AND account_name='05 - PET INSURANCE - NEW' AND chart_namespace='historical';

  UPDATE chart_of_accounts SET account_name='PET INSURANCE - RENEWAL'
  WHERE agency_id=v_agency AND account_name='05 - PET INSURANCE - RENEWAL' AND chart_namespace='historical';

  UPDATE chart_of_accounts SET account_name='SFVC'
  WHERE agency_id=v_agency AND account_name='06 - SFVC' AND chart_namespace='historical';

  UPDATE chart_of_accounts SET account_name='IPSI LIFE'
  WHERE agency_id=v_agency AND account_name='07 - IPSI LIFE' AND chart_namespace='historical';
END $$;

-- prior_year_pl section renames (pre-cutover display driver)
UPDATE public.prior_year_pl SET section='State Farm'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND section='4005 State Farm';

UPDATE public.prior_year_pl SET section='Alliances - SF Comp'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND section='Alliances';

UPDATE public.prior_year_pl SET section='IPS - SF Comp'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND section='IPS';

-- Merge IPSI LIFE ALLIANCE into IPSI LIFE and move both to IPS - SF Comp (no month overlap
-- verified — safe to relabel with no unique-key collision on natural key).
UPDATE public.prior_year_pl
SET section='IPS - SF Comp', account_name='IPSI LIFE'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND account_name IN ('07 - IPSI LIFE', '07 - IPSI LIFE ALLIANCE');

-- Strip other numbered prefixes in prior_year_pl
UPDATE public.prior_year_pl SET account_name='US BANK'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_name='03 - US BANK';

UPDATE public.prior_year_pl SET account_name='PET INSURANCE - NEW'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_name='05 - PET INSURANCE - NEW';

UPDATE public.prior_year_pl SET account_name='PET INSURANCE - RENEWAL'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_name='05 - PET INSURANCE - RENEWAL';

UPDATE public.prior_year_pl SET account_name='SFVC'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_name='06 - SFVC';

-- Keep post_sf_commission_recap's parent-name lookup working after the rename
UPDATE public.settings SET setting_value='State Farm'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND setting_key='gl_default_sf_revenue_account_name';
