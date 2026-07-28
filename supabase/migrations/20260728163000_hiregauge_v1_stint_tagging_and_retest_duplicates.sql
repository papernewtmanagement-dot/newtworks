-- Newtworks v1 Stint 2 build, steps 3 + 7 of 10 per handoff 2026-07-28.
--
-- STEP 3: tag every newtworks_v1_personality item into stint 1 (best 5
-- indicators per trait; served to every candidate) or stint 2 (rest;
-- served on demand when a borderline score fires an expansion trigger).
--
-- Selection criteria for the 45 stint=1 picks:
--   1. Face validity — item semantically maps cleanly to the target trait
--   2. Keyed / reverse-coded balance — 2 to 3 of each so acquiescence bias
--      surfaces on the primary sitting
--   3. Range coverage — mix intense vs moderate wording
-- Approximate-fit traits (deadline_motivation, recognition_drive,
-- self_promotion) picked closest-to-construct items from their approximate
-- source pool; v1.1 will improve those separately.
--
-- Best 5 per trait → stint=1.
UPDATE public.hiregauge_instrument_items
SET stint = 1
WHERE section = 'newtworks_v1_personality'
  AND item_number IN (
    -- analytical: process (13/17/18) + cognitive floor rev (20/23)
    13, 17, 18, 20, 23,
    -- assertiveness: charge/voice/criticism (24/26/27) + passivity rev (30/33)
    24, 26, 27, 30, 33,
    -- belief_in_others: distrust/hidden motives rev (55/57) + trust others / good intentions / moral (61/62/63)
    55, 57, 61, 62, 63,
    -- compassion: emotion/interest/time (3/4/7) + not-interested/needy rev (9/10)
    3, 4, 7, 9, 10,
    -- deadline_motivation: chores/exacting (95/98) + procrastination/mess rev (101/102/103)
    95, 98, 101, 102, 103,
    -- independent_spirit: alone/privacy (85/86/90) + teamwork/company rev (92/93)
    85, 86, 90, 92, 93,
    -- optimism: not-bothered/not-discouraged (82/83) + worry/past-mistakes/crushed rev (77/78/80)
    82, 83, 77, 78, 80,
    -- recognition_drive: comfortable/attention/starts-conversations (44/46/48) + quiet-strangers/background rev (52/53)
    -- Friendliness half only; Gregariousness half (34-43) rolls to stint=2
    44, 46, 48, 52, 53,
    -- self_promotion: open-about-self / disclose / talk-about-self (69/71/73) + reveal-little / hard-to-know rev (64/65)
    69, 71, 73, 64, 65
  );

-- Remaining newtworks_v1_personality items → stint=2.
UPDATE public.hiregauge_instrument_items
SET stint = 2
WHERE section = 'newtworks_v1_personality'
  AND stint IS NULL;

-- STEP 7: 5 retest duplicates. Each duplicates a stint=1 item with a new
-- item_number in the 200 range so it sorts later in the served sequence;
-- retest_of_item_number FK points back to the original for scoring's
-- test-retest divergence calculation. Spread across 5 different traits,
-- 3 keyed + 2 reverse.
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense,
   retest_of_item_number, hypothesized_trait, reverse_coded, scale_max,
   stint, notes)
SELECT
  'newtworks_v1_personality',
  new_num,
  src.item_text,
  src.choices,
  src.answer_key,
  src.is_nonsense,
  src.item_number,
  src.hypothesized_trait,
  src.reverse_coded,
  src.scale_max,
  1,
  'Retest duplicate of item ' || src.item_number || ' (' || src.hypothesized_trait
    || '). Same item text served later in sequence to catch response-consistency drift.'
FROM public.hiregauge_instrument_items src
JOIN (VALUES
  (200, 13),   -- analytical, keyed:  "Tend to analyze things."
  (201, 27),   -- assertiveness, keyed:  "Am not afraid of providing criticism."
  (202, 57),   -- belief_in_others, reverse:  "Distrust people."
  (203, 77),   -- optimism, reverse:  "Worry about things."
  (204, 46)    -- recognition_drive, keyed:  "Don't mind being the center of attention."
) AS pairs(new_num, src_num)
  ON src.item_number = pairs.src_num
WHERE src.section = 'newtworks_v1_personality';
