-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 04:07:23 UTC (ledger name: rename_bcc_to_newtworks_persistent_memory) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706040723.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Rename BCC → Newtworks in persistent_memory content + titles
-- Order matters: specific compounds first, word-boundary BCC last
UPDATE public.persistent_memory
SET content = REGEXP_REPLACE(
                REGEXP_REPLACE(
                  REGEXP_REPLACE(
                    REGEXP_REPLACE(
                      REGEXP_REPLACE(content, 'BCCApp', 'NewtworksApp', 'g'),
                      'storybccdashboard', 'newtworks', 'g'),
                    'Business Command Center', 'Newtworks', 'g'),
                  '\ybcc-', 'newtworks-', 'g'),
                '\yBCC\y', 'Newtworks', 'g'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND (content ~ '\yBCC\y' 
       OR content ILIKE '%Business Command Center%' 
       OR content ILIKE '%storybccdashboard%'
       OR content ~ '\ybcc-'
       OR content ILIKE '%BCCApp%');

-- Rename titles that lead with "BCC " to "Newtworks "
UPDATE public.persistent_memory
SET title = REGEXP_REPLACE(title, '^BCC ', 'Newtworks ', 'g'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND title ~ '^BCC ';

-- Also rename "BCC" mid-title if any
UPDATE public.persistent_memory
SET title = REGEXP_REPLACE(title, '\yBCC\y', 'Newtworks', 'g'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND title ~ '\yBCC\y';
