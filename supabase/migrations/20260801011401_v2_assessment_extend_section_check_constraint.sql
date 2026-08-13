-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 01:14:01 UTC (ledger name: v2_assessment_extend_section_check_constraint) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801011401.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Extend the hiregauge_instrument_items.section CHECK constraint to allow v2 sections.
-- v2 architecture (parallel columns) adds four new sections; v1 sections retained.

ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_section_check;

ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY[
    'instructions'::text,
    'vct'::text,
    'cognitive'::text,
    'cts'::text,
    'newtworks_v1_personality'::text,
    'newtworks_v1_impression_mgmt'::text,
    'newtworks_v1_vct'::text,
    'newtworks_v2_personality'::text,
    'newtworks_v2_cognitive_icar16'::text,
    'newtworks_v2_impression_mgmt'::text,
    'newtworks_v2_vct'::text
  ]));
