-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-27 21:39:19 UTC (ledger name: drop_chart_namespace_column_and_setting) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260727213919.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Remove the setting row + column now that no code references it
DELETE FROM public.settings
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND setting_key='gl_chart_namespace';

ALTER TABLE public.chart_of_accounts DROP COLUMN IF EXISTS chart_namespace;
