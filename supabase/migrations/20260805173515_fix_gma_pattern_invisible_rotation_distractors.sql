-- Items 3, 4, 5 (section newtworks_v2_cognitive_gma, gma_pattern) each used
-- option E = the correct answer F's shape rotated 90 degrees. Squares and
-- circles are rotation-invariant at 90, so E rendered pixel-identical to F --
-- two indistinguishable answer options, item unanswerable by inspection.
-- Caught by the 2026-08-05 self-test on item 3 (active, stint 1); a
-- same-class sweep found items 4 and 5 in the inactive stint-2 pool. Item 6
-- was already rebuilt for exactly this trap ("rotation dimension is visible
-- in every cell"); these three predate that fix. Replacements play each
-- item's own unused visible dimension, keeping the "near-miss" distractor
-- intent:
--   item 3 (shape elimination, all-solid all-medium grid): E -> outline medium square (right shape, wrong fill)
--   item 4 (fill elimination, fills exhausted in A/B/F):   E -> small solid circle (right shape+fill, wrong size)
--   item 5 (size elimination, sizes exhausted in A/B/F):   E -> outline medium square (right shape+size, wrong fill)
UPDATE public.hiregauge_instrument_items
SET choices = jsonb_set(choices, '{options,E}', '{"fill":"outline","size":"m","count":1,"shape":"square","rotation":0}'::jsonb), updated_at = NOW()
WHERE section = 'newtworks_v2_cognitive_gma' AND item_number = 3;

UPDATE public.hiregauge_instrument_items
SET choices = jsonb_set(choices, '{options,E}', '{"fill":"solid","size":"s","count":1,"shape":"circle","rotation":0}'::jsonb), updated_at = NOW()
WHERE section = 'newtworks_v2_cognitive_gma' AND item_number = 4;

UPDATE public.hiregauge_instrument_items
SET choices = jsonb_set(choices, '{options,E}', '{"fill":"outline","size":"m","count":1,"shape":"square","rotation":0}'::jsonb), updated_at = NOW()
WHERE section = 'newtworks_v2_cognitive_gma' AND item_number = 5;
