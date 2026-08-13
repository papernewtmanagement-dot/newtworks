-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 02:49:04 UTC (ledger name: personal_property_tax_leaf_and_reroute) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730024904.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- 1. Create COA-PERSONAL-9910 Personal Property Tax
INSERT INTO public.chart_of_accounts (agency_id, account_code, account_name, account_type, account_subtype, business_entity_id, is_active, is_system)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'COA-PERSONAL-9910',
  'Personal Property Tax',
  'expense',
  'tax',
  'b3333333-3333-3333-3333-333333333333',
  true,
  false
)
ON CONFLICT DO NOTHING;

-- 2. Re-route the 3 property tax journal_lines to the new leaf
UPDATE public.journal_lines
SET account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND account_code = 'COA-PERSONAL-9910'
)
WHERE id IN (
  '74093a37-edf4-4e5a-af12-95d066411020',  -- COMAL COUNTY $2,741.81
  '4568d016-b30f-4c47-8973-6875fa5f250b',  -- JP Bexar $3,380.30
  'd3db64b1-1ef6-4030-b4ba-b1d34822e7a1'   -- JP Bexar $91.25
);

-- 3. Mark the 3 JEs classified (they were pending only because of the misclassification)
UPDATE public.journal_entries
SET classification_status = 'classified',
    classified_at = NOW(),
    classified_by = 'claude_conversation'
WHERE id IN (
  '3f18bd1e-28ef-4fb4-adcf-c4f81c7943c1',
  '0b359339-0768-490d-a03a-d1c9e2cea746',
  '63dbfd79-2214-497e-aed2-f9d4b9b5779a'
);
