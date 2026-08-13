-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 04:07:38 UTC (ledger name: rename_bcc_to_newtworks_content_tables) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706040738.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Same pattern applied to the three content tables
UPDATE public.processes
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
WHERE content ~ '\yBCC\y' 
   OR content ILIKE '%Business Command Center%'
   OR content ILIKE '%storybccdashboard%'
   OR content ~ '\ybcc-'
   OR content ILIKE '%BCCApp%';

UPDATE public.handbook
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
WHERE content ~ '\yBCC\y' 
   OR content ILIKE '%Business Command Center%'
   OR content ILIKE '%storybccdashboard%'
   OR content ~ '\ybcc-'
   OR content ILIKE '%BCCApp%';

UPDATE public.admin_pages
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
WHERE content ~ '\yBCC\y' 
   OR content ILIKE '%Business Command Center%'
   OR content ILIKE '%storybccdashboard%'
   OR content ~ '\ybcc-'
   OR content ILIKE '%BCCApp%';

-- Also update titles in these tables if any lead with "BCC "
UPDATE public.processes SET title = REGEXP_REPLACE(title, '\yBCC\y', 'Newtworks', 'g'), updated_at = NOW()
WHERE title ~ '\yBCC\y';
UPDATE public.handbook SET title = REGEXP_REPLACE(title, '\yBCC\y', 'Newtworks', 'g'), updated_at = NOW()
WHERE title ~ '\yBCC\y';
UPDATE public.admin_pages SET title = REGEXP_REPLACE(title, '\yBCC\y', 'Newtworks', 'g'), updated_at = NOW()
WHERE title ~ '\yBCC\y';
