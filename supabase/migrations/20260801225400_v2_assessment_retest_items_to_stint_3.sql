-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 22:54:00 UTC (ledger name: v2_assessment_retest_items_to_stint_3) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801225400.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- The 22 retest items (1 per facet) were authored into stint=2 alongside the
-- core battery, which caused the v2 delivery build to serve them
-- unconditionally to every candidate. That's wrong -- per OQ 52220bd5, these
-- are Stint 3 content: served only to facets whose stint 1+2 combined score
-- comes back ambiguous, not to everyone. Reclassifying them to stint=3 so
-- the delivery layer can hold them back and serve them conditionally.
--
-- Known gap, flagged not hidden: OQ 52220bd5 targets 2-4 expansion items per
-- triggered facet; only 1 retest item per facet currently exists. This
-- unblocks a functioning Stint 3 mechanism, it does not fully satisfy the
-- original item-count target. Authoring additional per-facet items (sourced
-- from the same published instruments, most of which are already fully
-- utilized at 10/10 items -- see notes on stint 1/2 items) is separate,
-- not-yet-scoped work.
UPDATE public.hiregauge_instrument_items
SET stint = 3
WHERE section = 'newtworks_v2_personality'
  AND retest_of_item_number IS NOT NULL
  AND stint = 2;
