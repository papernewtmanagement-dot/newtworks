-- Peter directive 2026-07-29: Consolidate agency expense taxonomy under the six
-- 0001-0006 parent categories. "0007 VEHICLES" was never authorized (only exists
-- as a section tag on prior_year_pl rows imported from QBO). Move that historical
-- data under 0005 DISCRETIONARY (matches the live agency pattern where every
-- vehicle-family COA-SUB-* row already nests under 0005). Then reparent 76 active
-- expense accounts (11 legacy headers + 65 orphan leaves) under the appropriate
-- 0001-0006 parent so every subcategory has a parent.
--
-- Scope: agency entity Peter Story State Farm (b2222222) only. Other entities
-- (PaperNewt LLC, Personal root, Story Business Admin, Eriosto) untouched.

-- ==========================================================================
-- Step 1: Retag prior_year_pl "0007 VEHICLES" -> "0005 DISCRETIONARY"
-- ==========================================================================
UPDATE public.prior_year_pl
SET section = '0005 DISCRETIONARY'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id = 'b2222222-2222-2222-2222-222222222222'
  AND section = '0007 VEHICLES';

-- ==========================================================================
-- Step 2: Reparent 76 chart_of_accounts rows under 0001-0006
-- ==========================================================================
-- 0001 ADMINISTRATION: Occupancy, Tech/Software, Professional Services,
-- Insurance, G&A, Other Non-Op, plus the Reimbursements catch-all
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='COA-019'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code IN (
    -- Occupancy family
    '6200','6210','6220','6230','6240','6250',
    -- Technology & Software family
    '6300','6310','6311','6312','6313','6314','6315','6320','6330','6340',
    -- Professional Services family
    '6500','6510','6520','6530','6540',
    -- Insurance family
    '6600','6610','6620','6630',
    -- General & Administrative family
    '6900','6910','6920','6930','6940','6941','6942','6950','6960',
    -- Other Non-Operating family
    '8000','8020','8040',
    -- Reimbursements catch-all
    'COA-SUB-088'
  );

-- 0003 TEAM: Payroll & Compensation family (header + 6 cascading children),
-- Employee Benefits family, Education & Licensing family
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='COA-020'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code IN (
    -- Payroll & Compensation header (6010/6011/6012/6013/6020/6030/6031-6034/
    -- 6040/6050/6060 cascade via 6000, don't need direct-parent)
    '6000',
    -- Employee Benefits family (6100 header + all leaves direct-parented)
    '6100','6110','6115','6120','6130',
    -- Education & Licensing family (6700 header + 6720/6730/6740/6750
    -- direct-parented; 6710/6715 cascade via 6700)
    '6700','6720','6730','6740','6750'
  );

-- 0004 MARKETING: Marketing & Advertising family
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='COA-021'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code IN (
    '6400','6410','6420','6430','6440','6450','6460','6470'
  );

-- 0005 DISCRETIONARY: Vehicle & Travel family + Meals & Entertainment
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='COA-031'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code IN (
    '6800','6810','6820','6830','6840','6850','6860'
  );

