-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 23:20:53 UTC (ledger name: v2_assessment_port_faking_good_and_careless_check) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801232053.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Port v1's faking-good (impression management) content to v2, unchanged
-- content, new section per Path A self-contained-v2 doctrine (matches the
-- pattern already used for a few duplicated personality items, e.g.
-- "v1 dup: assertiveness item 24... Path A self-contained v2 flow").
-- Spec: 10 total (4 stint 1 + 6 stint 2). Splitting the existing 10 items
-- 4/6 by item_number order -- no reason to prefer one item over another for
-- which half lands in which stint, so first 4 by item_number go to stint 1,
-- remaining 6 to stint 2.
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, stint, item_text, scale_max, is_nonsense, is_active, notes)
SELECT
  'newtworks_v2_personality',
  300 + item_number,  -- new numbering block, clear of existing 1-244 range
  CASE WHEN item_number <= 4 THEN 1 ELSE 2 END,
  item_text, scale_max, is_nonsense, true,
  notes || ' | Ported from newtworks_v1_impression_mgmt item ' || item_number || ' to v2 2026-08-01 (faking-good check, Path A self-contained v2 flow). hypothesized_trait intentionally NULL -- this is a validity check, not a scored personality facet.'
FROM public.hiregauge_instrument_items
WHERE section = 'newtworks_v1_impression_mgmt' AND stint = 1;

-- Port 4 of the 8 v1 nonsense/fabricated words as the careless-answer check
-- (stint 1, per spec). Selecting the 4 lowest item_number for determinism.
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, stint, item_text, choices, scale_max, is_nonsense, answer_key, is_active, notes)
SELECT
  'newtworks_v2_personality',
  320 + item_number,
  1,
  item_text, choices, scale_max, is_nonsense, answer_key, true,
  notes || ' | Ported from newtworks_v1_vct item ' || item_number || ' to v2 2026-08-01 (careless-answer check, Path A self-contained v2 flow).'
FROM public.hiregauge_instrument_items
WHERE section = 'newtworks_v1_vct' AND is_nonsense = true
ORDER BY item_number
LIMIT 4;

SELECT
  (SELECT count(*) FROM public.hiregauge_instrument_items WHERE section='newtworks_v2_personality' AND item_number BETWEEN 301 AND 310) AS faking_good_ported,
  (SELECT count(*) FROM public.hiregauge_instrument_items WHERE section='newtworks_v2_personality' AND item_number BETWEEN 321 AND 330) AS careless_check_ported;
