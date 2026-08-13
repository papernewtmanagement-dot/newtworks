-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 02:04:32 UTC (ledger name: delete_v1_assessment_items) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802020432.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Delete all non-v2 items from hiregauge_instrument_items.
-- FK on hiregauge_candidate_responses.item_id is ON DELETE CASCADE,
-- so tied responses will delete as well. Score summaries on hiring_candidates
-- are stored columns, unaffected.
-- Verified: zero v2 items reference any v1 items via retest_of_item_number
-- (retest scope is per-section, and cross-section join returned zero orphans).

DELETE FROM hiregauge_instrument_items
WHERE section NOT LIKE 'newtworks_v2%';

-- Also drop Perseverance from v2_personality (dropped-facet cleanup per this session).
DELETE FROM hiregauge_instrument_items
WHERE section='newtworks_v2_personality' AND hypothesized_trait='perseverance';
