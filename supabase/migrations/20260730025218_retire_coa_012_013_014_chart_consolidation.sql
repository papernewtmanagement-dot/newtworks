-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 02:52:18 UTC (ledger name: retire_coa_012_013_014_chart_consolidation) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730025218.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- 1. Move 26 COA-012 (Chase Marketing 2 / 7770) lines → COA-011 (Chase Marketing 1, primary card)
UPDATE public.journal_lines
SET account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-011'
)
WHERE account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-012'
);

-- 2. Move 26 COA-014 (SF Card Peter / 4676) lines → COA-036 (US Bank Business 3447 master)
UPDATE public.journal_lines
SET account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-036'
)
WHERE account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-014'
);

-- 3. Deactivate the three retired chart accounts
UPDATE public.chart_of_accounts
SET is_active = false
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_code IN ('COA-012','COA-013','COA-014');
