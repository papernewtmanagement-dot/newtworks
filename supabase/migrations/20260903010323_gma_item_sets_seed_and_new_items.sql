-- Step 1b of the 2026-09-02 GMA Section 1 swap: the four replacement items
-- (INACTIVE until step 2), the two named item sets, their members, and the
-- backfill that locks every candidate who has already answered a GMA item to
-- the 2026-08-02 set.
--
-- The items are generated + verified by tools/gma_generate_v5_swap.py: every
-- grid cell is re-derived from the rule tables, options are checked for
-- duplicates and for pairs that look identical on screen after rotation
-- normalisation, and each verbal distractor carries a written reason it does
-- not satisfy the stated relation. Never hand-typed (op-rule "GMA matrix
-- items -- build via code generator on CJS(1990)").
--
-- WHY THESE FOUR ARE RETIRED (p on the first 19 completions of the fixed set):
--   pattern 1  1.00   verbal 67  1.00
--   pattern 3  0.95   verbal 61  0.95
-- An item everyone answers correctly contributes p(1-p) = 0 to score variance
-- (Nunnally & Bernstein 1994, Psychometric Theory ch. 8); for a 6-option item
-- reliability is maximised near p = .58 (Lord 1952, Psychometrika 17:181-194).
-- The numerical trio at p = .84 (items 31, 34, 42) are the next candidates if
-- spread is still short at N >= 20 on the new set. Peter ruling 2026-09-02:
-- swap, do not expand -- the count stays at 16.
--
-- WHY THE REPLACEMENTS SHOULD LAND NEAR p = .50-.60: matrix difficulty is
-- driven by the number and type of rules stacked (Carpenter, Just & Shell
-- 1990, Psychological Review 97(3):404-431; Embretson 1998, Psychological
-- Methods 3:380-396). Observed on this bank: 2 rules with one perceptual rule
-- (item 6) = .79, 3 rules (item 10) = .32. Items 76 and 77 each stack two
-- CONCEPTUAL rules -- distribution-of-two (the hardest single CJS type) or
-- figure addition, plus a Latin-square distribution. Items 78 and 79 use less
-- transparent relations (person:defining-attitude, collection:member) with
-- distractors strongly associated with the third term that do not carry the
-- relation (Sternberg 1977; Bejar, Chaffin & Embretson 1991) -- the structure
-- that makes item 71 (Key:Lock::Password:Account, p = .42) discriminate while
-- item 67 (Wheel:Car::Sail:Boat, p = 1.00) does not.

INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, cognitive_domain, stint, is_active)
VALUES
(
  'newtworks_v2_cognitive_gma', 76, 'Shape (circle/square/triangle) appears once per row and once per column; fill is solid except for exactly one striped shape per row, and the striped one shifts position each row (distribution-of-two). Two rules stacked.',
  '{"grid": [{"shape": "circle", "fill": "striped", "size": "m", "count": 1, "rotation": 0}, {"shape": "square", "fill": "solid", "size": "m", "count": 1, "rotation": 0}, {"shape": "triangle", "fill": "solid", "size": "m", "count": 1, "rotation": 0}, {"shape": "square", "fill": "solid", "size": "m", "count": 1, "rotation": 0}, {"shape": "triangle", "fill": "striped", "size": "m", "count": 1, "rotation": 0}, {"shape": "circle", "fill": "solid", "size": "m", "count": 1, "rotation": 0}, {"shape": "triangle", "fill": "solid", "size": "m", "count": 1, "rotation": 0}, {"shape": "circle", "fill": "solid", "size": "m", "count": 1, "rotation": 0}, null], "options": {"A": {"shape": "triangle", "fill": "striped", "size": "m", "count": 1, "rotation": 0}, "B": {"shape": "square", "fill": "striped", "size": "m", "count": 2, "rotation": 0}, "C": {"shape": "square", "fill": "solid", "size": "m", "count": 1, "rotation": 0}, "D": {"shape": "square", "fill": "striped", "size": "m", "count": 1, "rotation": 0}, "E": {"shape": "hexagon", "fill": "striped", "size": "m", "count": 1, "rotation": 0}, "F": {"shape": "circle", "fill": "striped", "size": "m", "count": 1, "rotation": 0}}}'::jsonb, 'D', 'gma_pattern', 1, false
),
(
  'newtworks_v2_cognitive_gma', 77, 'Fill (solid/outline/striped) appears once per row and once per column; the count in the third column equals the count in the first column plus the count in the second column, in every row. Two rules stacked.',
  '{"grid": [{"shape": "circle", "fill": "solid", "size": "m", "count": 1, "rotation": 0}, {"shape": "circle", "fill": "outline", "size": "m", "count": 1, "rotation": 0}, {"shape": "circle", "fill": "striped", "size": "m", "count": 2, "rotation": 0}, {"shape": "circle", "fill": "outline", "size": "m", "count": 1, "rotation": 0}, {"shape": "circle", "fill": "striped", "size": "m", "count": 2, "rotation": 0}, {"shape": "circle", "fill": "solid", "size": "m", "count": 3, "rotation": 0}, {"shape": "circle", "fill": "striped", "size": "m", "count": 2, "rotation": 0}, {"shape": "circle", "fill": "solid", "size": "m", "count": 1, "rotation": 0}, null], "options": {"A": {"shape": "hexagon", "fill": "outline", "size": "m", "count": 3, "rotation": 0}, "B": {"shape": "circle", "fill": "solid", "size": "m", "count": 3, "rotation": 0}, "C": {"shape": "circle", "fill": "outline", "size": "m", "count": 4, "rotation": 0}, "D": {"shape": "circle", "fill": "outline", "size": "m", "count": 2, "rotation": 0}, "E": {"shape": "arrow", "fill": "outline", "size": "m", "count": 3, "rotation": 0}, "F": {"shape": "circle", "fill": "outline", "size": "m", "count": 3, "rotation": 0}}}'::jsonb, 'F', 'gma_pattern', 1, false
),
(
  'newtworks_v2_cognitive_gma', 78, 'Optimist is to Hope as Skeptic is to ___',
  '["Doubt", "Trust", "Belief", "Proof", "Fear", "Certainty"]'::jsonb, 'Doubt', 'gma_verbal', 1, false
),
(
  'newtworks_v2_cognitive_gma', 79, 'Bouquet is to Flower as Constellation is to ___',
  '["Star", "Galaxy", "Sky", "Planet", "Telescope", "Zodiac"]'::jsonb, 'Star', 'gma_verbal', 1, false
)
ON CONFLICT (section, item_number) DO NOTHING;

INSERT INTO public.hiregauge_gma_item_sets
  (set_key, agency_id, label, is_current, activated_at, floor_pct_override, gate_c_max_correct_override, norm_status, notes)
VALUES
  ('fixed16_v1', '126794dd-25ff-47d2-a436-724499733365',
   'Fixed 16 items, 2026-08-02 (items 1,3,6,10 / 31,34,39,42 / 46,47,50,60 / 61,65,67,71)',
   true, '2026-08-25 00:00:00+00', 62.5, 3, 'rebuilt',
   'Reasoning floor 62.5% and gate C at <= 3 correct pinned by Peter ruling 2026-09-02 (candidates at 5, 6, 7 of 16 stay declined). The 2026-08-05 derivation behind 62.5 assumed 2-option items; the real chance + 2 SD on this set is 7 of 16 (43.75%). Kept as ruled. Norm: gma 74.11/17.84 (N=19), gma_speed 2.0094/0.9345 (N=16), rebuilt 2026-09-02.'),
  ('fixed16_v2', '126794dd-25ff-47d2-a436-724499733365',
   'Fixed 16 items, 2026-09-02 swap (retires 1,3,61,67 for 76,77,78,79)',
   false, '2026-09-02 00:00:00+00', NULL, NULL, 'provisional_seed',
   'Four near-ceiling items (p 0.95-1.00 on the first 19 completions) replaced by two 2-rule matrix items (distribution-of-two + Latin square; figure addition + Latin square) and two analogies with associative lures, targeting p 0.50-0.60. Floor and gate C derived from option counts (7 of 16 = 43.75%; gate C <= 3). Norm seeded from live data on the 12 surviving items; auto-rebuilds at N >= 20.')
ON CONFLICT (set_key) DO NOTHING;

INSERT INTO public.hiregauge_gma_item_set_members (set_key, item_id)
SELECT 'fixed16_v1', i.id
FROM public.hiregauge_instrument_items i
WHERE i.section = 'newtworks_v2_cognitive_gma'
  AND i.item_number IN (1,3,6,10,31,34,39,42,46,47,50,60,61,65,67,71)
ON CONFLICT DO NOTHING;

INSERT INTO public.hiregauge_gma_item_set_members (set_key, item_id)
SELECT 'fixed16_v2', i.id
FROM public.hiregauge_instrument_items i
WHERE i.section = 'newtworks_v2_cognitive_gma'
  AND i.item_number IN (6,10,31,34,39,42,46,47,50,60,65,71,76,77,78,79)
ON CONFLICT DO NOTHING;

-- Everyone who has answered any GMA item so far answered the 2026-08-02 set.
UPDATE public.hiring_candidates c
SET gma_item_set = 'fixed16_v1'
WHERE c.gma_item_set IS NULL
  AND EXISTS (
    SELECT 1 FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = c.id AND i.section = 'newtworks_v2_cognitive_gma'
  );
