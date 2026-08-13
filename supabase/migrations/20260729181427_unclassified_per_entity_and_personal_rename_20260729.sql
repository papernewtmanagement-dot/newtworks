-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-29 18:14:27 UTC (ledger name: unclassified_per_entity_and_personal_rename_20260729) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260729181427.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- 1. Rename entity "Peter Story" to "Personal"
UPDATE public.business_entities
SET name = 'Personal', updated_at = NOW()
WHERE id = 'b3333333-3333-3333-3333-333333333333'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 2. Create *Unclassified expense account per active entity
-- account_code pattern: COA-UNCL-<slug uppercase>
INSERT INTO public.chart_of_accounts
  (agency_id, business_entity_id, account_code, account_name, account_type, is_active, created_at)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  be.id,
  'COA-UNCL-' || UPPER(be.slug),
  '*Unclassified',
  'expense',
  true,
  NOW()
FROM public.business_entities be
WHERE be.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND be.status = 'active'
  AND NOT EXISTS (
    SELECT 1 FROM public.chart_of_accounts existing
    WHERE existing.agency_id = '126794dd-25ff-47d2-a436-724499733365'
      AND existing.business_entity_id = be.id
      AND existing.account_name = '*Unclassified'
  );

-- Verify creation
SELECT be.name AS entity, coa.account_code, coa.account_name, coa.account_type
FROM public.chart_of_accounts coa
JOIN public.business_entities be ON be.id = coa.business_entity_id
WHERE coa.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND coa.account_name = '*Unclassified'
ORDER BY be.name;
