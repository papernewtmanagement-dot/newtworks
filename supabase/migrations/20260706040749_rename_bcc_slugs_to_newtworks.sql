-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 04:07:49 UTC (ledger name: rename_bcc_slugs_to_newtworks) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706040749.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Rename confluence_page_id slugs from bcc-* to newtworks-*
-- Must also update parent_page_id (text FK) to keep tree relationships intact

-- processes
UPDATE public.processes
SET parent_page_id = REGEXP_REPLACE(parent_page_id, '^bcc-', 'newtworks-'),
    updated_at = NOW()
WHERE parent_page_id LIKE 'bcc-%';

UPDATE public.processes
SET confluence_page_id = REGEXP_REPLACE(confluence_page_id, '^bcc-', 'newtworks-'),
    updated_at = NOW()
WHERE confluence_page_id LIKE 'bcc-%';

-- handbook
UPDATE public.handbook
SET parent_page_id = REGEXP_REPLACE(parent_page_id, '^bcc-', 'newtworks-'),
    updated_at = NOW()
WHERE parent_page_id LIKE 'bcc-%';

UPDATE public.handbook
SET confluence_page_id = REGEXP_REPLACE(confluence_page_id, '^bcc-', 'newtworks-'),
    updated_at = NOW()
WHERE confluence_page_id LIKE 'bcc-%';

-- admin_pages
UPDATE public.admin_pages
SET parent_page_id = REGEXP_REPLACE(parent_page_id, '^bcc-', 'newtworks-'),
    updated_at = NOW()
WHERE parent_page_id LIKE 'bcc-%';

UPDATE public.admin_pages
SET confluence_page_id = REGEXP_REPLACE(confluence_page_id, '^bcc-', 'newtworks-'),
    updated_at = NOW()
WHERE confluence_page_id LIKE 'bcc-%';
