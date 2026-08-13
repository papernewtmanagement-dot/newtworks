-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 02:22:07 UTC (ledger name: drop_assured_dominance_and_perseverance) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802022207.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
DELETE FROM hiregauge_instrument_items
WHERE section='newtworks_v2_personality' AND hypothesized_trait='assured_dominance';

DELETE FROM hiregauge_trait_documentation
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND trait_name IN ('assured_dominance','perseverance');

ALTER TABLE hiring_candidates DROP COLUMN IF EXISTS assured_dominance;
ALTER TABLE hiring_candidates DROP COLUMN IF EXISTS perseverance;
