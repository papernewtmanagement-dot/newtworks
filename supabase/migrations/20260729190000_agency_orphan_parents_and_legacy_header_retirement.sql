-- Peter directive 2026-07-29 (continuation): (a) deactivate the nine childless
-- legacy expense headers that no longer aggregate anything after the six-parent
-- reparent, and (b) give every remaining orphan agency account a parent so the
-- balance sheet + P&L are fully hierarchical.
--
-- Scope: agency entity Peter Story State Farm (b2222222) only. Non-agency
-- entities (Personal, PaperNewt, Eriosto, Steward) lack established root
-- taxonomies — separate design decision.
--
-- Legitimate roots left parentless by design:
--   Expense:   COA-019/020/021/022/031/032 (0001-0006)
--   Income:    COA-018 State Farm, COA-033 Alliances - SF Comp,
--              COA-034 IPS - SF Comp, COA-035 External
--   Asset:     1000 Current Assets, 1500 Fixed Assets (header roots)
--   Liability: 2000 Current Liabilities, 2500 Long-Term Liabilities (header roots)
--   Equity:    3000 Equity (header root)
--   Payroll/Ed intermediate parents 6000 + 6700 stay active (still cascade
--   children under 0003 TEAM).

-- ==========================================================================
-- Step 1: Deactivate 9 childless legacy expense headers
-- ==========================================================================
UPDATE public.chart_of_accounts
SET is_active = false
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code IN (
    '6100', -- Employee Benefits
    '6200', -- Occupancy
    '6300', -- Technology & Software
    '6400', -- Marketing & Advertising
    '6500', -- Professional Services
    '6600', -- Insurance Expense
    '6800', -- Vehicle & Travel
    '6900', -- General & Administrative
    '8000'  -- Other Income & Expense
  );

-- ==========================================================================
-- Step 2: Agency INCOME orphans -> External (COA-035)
-- ==========================================================================
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='COA-035'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code IN (
    '4900',            -- Other Income (legacy header)
    'COA-UNCL-PSS-INC' -- Unclassified income catch-all
  );

-- ==========================================================================
-- Step 3: Agency ASSET orphans
-- ==========================================================================
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='1000'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code IN (
    'COA-001','COA-002','COA-003','COA-004','COA-005',
    'COA-006','COA-007','COA-008','COA-024','COA-SUSP'
  );

UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='1500'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code='COA-027';

-- ==========================================================================
-- Step 4: Agency LIABILITY orphans -> Current Liabilities (2000)
-- ==========================================================================
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='2000'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code IN (
    'COA-010','COA-011','COA-012','COA-013','COA-014',
    'COA-026','COA-028','COA-030','COA-036','COA-IC-001'
  );

-- ==========================================================================
-- Step 5: Agency EQUITY orphans -> Equity (3000)
-- ==========================================================================
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='3000'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_type='equity'
  AND account_code IN (
    '3010','3020','3030','3040','3050','3060',
    'COA-015','COA-029','COA-032'
  );
