-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 16:37:45 UTC (ledger name: gma_domain_and_section_labels) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801163745.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Expand cognitive_domain to allow the 4 new GMA subtests alongside the legacy 3
ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT hiregauge_instrument_items_cognitive_domain_check;
ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_cognitive_domain_check
  CHECK (cognitive_domain = ANY (ARRAY[
    'verbal'::text, 'math'::text, 'problem_solving'::text,
    'gma_pattern'::text, 'gma_deductive'::text, 'gma_numerical'::text, 'gma_verbal'::text
  ]) OR cognitive_domain IS NULL);

-- Rename the empty, never-used 'newtworks_v2_cognitive_icar16' section label to
-- 'newtworks_v2_cognitive_gma' -- 0 rows reference it (confirmed before running this),
-- it was reserved before we hit ICAR's access wall and pivoted to original items.
ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT hiregauge_instrument_items_section_check;
ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY[
    'instructions'::text, 'vct'::text, 'cognitive'::text, 'cts'::text,
    'newtworks_v1_personality'::text, 'newtworks_v1_impression_mgmt'::text, 'newtworks_v1_vct'::text,
    'newtworks_v2_personality'::text, 'newtworks_v2_cognitive_gma'::text,
    'newtworks_v2_impression_mgmt'::text, 'newtworks_v2_vct'::text
  ]));
