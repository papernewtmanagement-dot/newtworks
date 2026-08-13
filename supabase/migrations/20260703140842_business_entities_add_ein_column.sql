-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-03 14:08:42 UTC (ledger name: business_entities_add_ein_column) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260703140842.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Add EIN column to business_entities (entity-level tax ID, unambiguous per-entity)
ALTER TABLE public.business_entities
  ADD COLUMN IF NOT EXISTS ein text;

COMMENT ON COLUMN public.business_entities.ein IS 'Federal Employer Identification Number for this entity. Format: XX-XXXXXXX';

-- Populate Peter Story State Farm's EIN
UPDATE public.business_entities
SET ein = '83-1295615', updated_at = NOW()
WHERE id = 'b2222222-2222-2222-2222-222222222222';
