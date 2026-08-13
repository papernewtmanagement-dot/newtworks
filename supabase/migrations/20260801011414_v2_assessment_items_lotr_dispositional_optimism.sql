-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 01:14:14 UTC (ledger name: v2_assessment_items_lotr_dispositional_optimism) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801011414.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- v2 assessment items: LOT-R Dispositional Optimism (6 scored items)
-- Source: Scheier, Carver & Bridges 1994, JPSP 67(6), 1063-1078
-- Sourced from Charles Carver's canonical instrument page:
--   https://www.psy.miami.edu/faculty/ccarver/lot-r.html
-- Public with attribution. 5-point scale (agree a lot -> disagree a lot).
-- Filler items 2, 5, 6, 8 (from published 10-item scale) NOT ingested per handoff loose thread #4.
-- All items go to Stint 2 (Tier 3 in handoff structure).

INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, hypothesized_trait, reverse_coded, notes, scale_max, stint)
VALUES
  ('newtworks_v2_personality', 1,
   'In uncertain times, I usually expect the best.',
   'dispositional_optimism', false,
   'LOT-R published item 1. Scheier, Carver & Bridges 1994. Optimism-worded (high value = high optimism).',
   5, 2),
  ('newtworks_v2_personality', 2,
   'If something can go wrong for me, it will.',
   'dispositional_optimism', true,
   'LOT-R published item 3. Scheier, Carver & Bridges 1994. Pessimism-worded, reverse-coded (high raw = low optimism).',
   5, 2),
  ('newtworks_v2_personality', 3,
   'I''m always optimistic about my future.',
   'dispositional_optimism', false,
   'LOT-R published item 4. Scheier, Carver & Bridges 1994. Optimism-worded.',
   5, 2),
  ('newtworks_v2_personality', 4,
   'I hardly ever expect things to go my way.',
   'dispositional_optimism', true,
   'LOT-R published item 7. Scheier, Carver & Bridges 1994. Pessimism-worded, reverse-coded.',
   5, 2),
  ('newtworks_v2_personality', 5,
   'I rarely count on good things happening to me.',
   'dispositional_optimism', true,
   'LOT-R published item 9. Scheier, Carver & Bridges 1994. Pessimism-worded, reverse-coded.',
   5, 2),
  ('newtworks_v2_personality', 6,
   'Overall, I expect more good things to happen to me than bad.',
   'dispositional_optimism', false,
   'LOT-R published item 10. Scheier, Carver & Bridges 1994. Optimism-worded.',
   5, 2);
