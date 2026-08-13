-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 19:09:18 UTC (ledger name: fix_agency_name_in_scripts_and_drop_ace_header) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810190918.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- 1. Restore the agency's trading name in every script line the 2026-07-07
--    name-scrub mangled. "the agent State Farm" is never correct English and is
--    always the redaction artifact. Peter directive 2026-08-10.
UPDATE public.manuals
SET content = replace(content, 'the agent State Farm', 'Peter Story State Farm'),
    version = version + 1, updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND content LIKE '%the agent State Farm%';

-- 2. Drop the "Find Impact Together" banner from every FIT page.
--    Remove the marker from the four hosts, remove the inline copy from the
--    FIT Conversations parent, then hard-delete the fragment row.
UPDATE public.manuals
SET content = regexp_replace(
      content,
      '\*?\[Embedded excerpt from: ACE Header\]\*?\s*\n?\n?', '', 'g'),
    version = version + 1, updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND content LIKE '%[Embedded excerpt from: ACE Header]%';

UPDATE public.manuals
SET content = regexp_replace(
      content,
      '>\s*ℹ️\s*\*\*Find Impact Together to get a great FIT for customers\*\*\s*\n?\n?', '', 'g'),
    version = version + 1, updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND content LIKE '%Find Impact Together%';

DELETE FROM public.manuals
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'excerpt'
  AND lower(trim(title)) = 'ace header';
