-- Trim cognitive pool from 31 → 17 items and consolidate all v1 cognitive into stint 1.
-- Cognitive belongs in stint 1 for every candidate (rollback of v9 forced-expansion).

-- Deactivate 14 redundant cognitive items: 4 math + 7 verbal + 3 problem-solving
UPDATE hiregauge_instrument_items
SET is_active = false
WHERE section = 'cognitive'
  AND item_number IN (
    -- math: near-duplicates of kept series/proportion items
    50, 54, 55, 39,
    -- verbal: near-duplicates of kept series/analogy items
    56, 57, 42, 45, 46, 58, 59,
    -- problem-solving: 52+53 rate/speed near-duplicates of 66, 63 sequence redundant with math items
    52, 53, 63
  );

-- Retag kept problem-solving items from stint 2 → stint 1 (all currently stint 2)
UPDATE hiregauge_instrument_items
SET stint = 1
WHERE section = 'cognitive'
  AND cognitive_domain = 'problem_solving'
  AND item_number IN (61, 62, 64, 65, 66);

-- Retag kept math items from stint 2 → stint 1
UPDATE hiregauge_instrument_items
SET stint = 1
WHERE section = 'cognitive'
  AND cognitive_domain = 'math'
  AND item_number IN (37, 40);

-- Retag kept verbal items from stint 2 → stint 1
UPDATE hiregauge_instrument_items
SET stint = 1
WHERE section = 'cognitive'
  AND cognitive_domain = 'verbal'
  AND item_number IN (44, 48, 49);
