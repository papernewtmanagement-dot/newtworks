-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 04:22:06 UTC (ledger name: rename_bcc_to_newtworks_core_principles) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706042206.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Same regex chain applied to core_principles; only the 3 rows Peter approved
UPDATE public.core_principles
SET content = REGEXP_REPLACE(
                REGEXP_REPLACE(content, 'Business Command Center', 'Newtworks', 'g'),
                '\yBCC\y', 'Newtworks', 'g'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND (content ~ '\yBCC\y' OR content ILIKE '%Business Command Center%');

-- Verify
SELECT domain, 
       (content ~ '\yBCC\y' OR content ILIKE '%Business Command Center%') AS still_has_bcc
FROM public.core_principles
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' 
  AND is_active = true;
