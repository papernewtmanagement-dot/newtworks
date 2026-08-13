-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-27 21:46:25 UTC (ledger name: delete_empty_duplicate_income_scaffolds_and_deprecated_personal_accounts) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260727214625.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Delete 20 empty accounts identified as duplicate scaffolds (Group A: 18) or explicitly deprecated (Group D: 2)
-- All verified: 0 journal_lines, 0 bank_transactions, 0 bank_account_map, 0 credit_accounts, 0 external children
-- Two-step to respect chart_of_accounts.parent_account_id FK (NO ACTION): children first, then parents

-- Step 1: Delete leaf accounts and standalone accounts
DELETE FROM public.chart_of_accounts
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND account_code IN (
    -- 4000 SF Commission Income tree — 5 children
    '4010','4020','4030','4040','4050',
    -- 4100 SF Bonus Income tree — 6 children
    '4110','4120','4130','4140','4150','4160',
    -- 4900 Other Income tree — 2 empty children (4900 parent stays with 4920 Interest Income child)
    '4910','4930',
    -- Standalone income scaffolds
    '8010','8030',
    -- Personal-side unclassified + deprecated
    'COA-PERSONAL-8999',
    'COA-PERSONAL-9130',
    'COA-PERSONAL-CC-1247'
  );

-- Step 2: Delete newly-childless parent scaffolds
DELETE FROM public.chart_of_accounts
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND account_code IN ('4000', '4100');
