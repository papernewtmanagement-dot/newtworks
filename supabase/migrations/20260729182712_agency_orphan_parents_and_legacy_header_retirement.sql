-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-29 18:27:12 UTC (ledger name: agency_orphan_parents_and_legacy_header_retirement) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260729182712.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
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
-- Current Assets bucket (1000): cash, bank accounts, suspense
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
    'COA-001',  -- Cash on Hand
    'COA-002',  -- TRB Discretionary
    'COA-003',  -- TRB Expenses
    'COA-004',  -- TRB Income
    'COA-005',  -- TRB Marketing
    'COA-006',  -- US Bank - Expenses
    'COA-007',  -- US Bank - Income
    'COA-008',  -- Uncategorized Asset
    'COA-024',  -- Checking, State Farm (2353)
    'COA-SUSP'  -- Suspense (split offset pending)
  );

-- Fixed Assets bucket (1500): intangibles like Book of Business
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='1500'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code IN (
    'COA-027'  -- Book of Business - Flood
  );

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
    'COA-010',    -- Capital One Personal Card
    'COA-011',    -- Chase - Marketing 1
    'COA-012',    -- Chase - Marketing 2
    'COA-013',    -- SF Card - Expenses, Alvi
    'COA-014',    -- SF Card - Expenses, Peter
    'COA-026',    -- Spark - Discretionary
    'COA-028',    -- CITI Personal Card
    'COA-030',    -- Accounts Payable (A/P)
    'COA-036',    -- US Bank Business Cash Rewards 3447
    'COA-IC-001'  -- Due to PaperNewt LLC (intercompany)
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
    '3010',    -- Owner Capital / Paid-In Capital
    '3020',    -- Owner Draws
    '3030',    -- Retained Earnings
    '3040',    -- Current Year Earnings
    '3050',    -- S-Corp Distributions
    '3060',    -- Shareholder Loan Payable
    'COA-015', -- Opening Balance Equity
    'COA-029', -- Retained Earnings (legacy)
    'COA-032'  -- Pre-2025 Carryforward (plug) -- equity, distinct from COA-032 expense (0002 GROWTH)
  );
