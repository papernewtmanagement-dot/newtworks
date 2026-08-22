-- Content fixes:
--   Part 1: normalize scale_max on my prior retest items 205-207 (should be 5, not 7)
--   Part 2: deactivate 3 off-construct items (stint=2 personality items 19, 21, 54)
--   Part 3: insert 10 replacement + counterweight items to fix content and rebalance
--           directional skew in belief_in_others, compassion, independent_spirit,
--           optimism, analytical stint 2 pools.

-- Part 1: fix scale_max on retest items I added earlier this session
UPDATE public.hiregauge_instrument_items
SET scale_max = 5, updated_at = NOW()
WHERE section='newtworks_v1_personality'
  AND item_number IN (205, 206, 207)
  AND stint = 2;

-- Part 2: deactivate 3 off-construct stint=2 personality items
-- Items 19, 21: analytical trait but measure self-view-of-specialness (narcissism inflator)
-- Item 54: belief_in_others trait but measures forgiveness, not trust
UPDATE public.hiregauge_instrument_items
SET is_active = false,
    notes = COALESCE(notes || ' | ', '') || 'Deactivated: off-construct per soundness review',
    updated_at = NOW()
WHERE section='newtworks_v1_personality'
  AND stint = 2
  AND item_number IN (19, 21, 54);

-- Part 3: insert 10 new stint=2 personality items
-- 208-209 replace analytical items 19, 21 with real analytical-thinking items
-- 210-211 replace belief_in_others item 54 and add counterweight for positive skew
-- 212-213 counterweight compassion (was 4 pos / 1 rev)
-- 214-215 counterweight independent_spirit (was 4 pos / 1 rev)
-- 216-217 counterweight optimism (was 1 pos / 4 rev; items match Emotional Stability construct)
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense,
   retest_of_item_number, hypothesized_trait, reverse_coded, scale_max, stint, is_active, notes)
VALUES
  ('newtworks_v1_personality', 208,
   'Make rash decisions.',
   NULL, NULL, false, NULL, 'analytical', true, 5, 2, true,
   'Replacement for deactivated item 19; measures actual analytical deliberation'),
  ('newtworks_v1_personality', 209,
   'Jump into things without thinking.',
   NULL, NULL, false, NULL, 'analytical', true, 5, 2, true,
   'Replacement for deactivated item 21; measures actual analytical deliberation'),
  ('newtworks_v1_personality', 210,
   'Believe that most people are basically good.',
   NULL, NULL, false, NULL, 'belief_in_others', false, 5, 2, true,
   'Replacement for deactivated item 54; measures actual trust construct'),
  ('newtworks_v1_personality', 211,
   'Feel that most people can be trusted.',
   NULL, NULL, false, NULL, 'belief_in_others', false, 5, 2, true,
   'Counterweight for positive-skew rebalance on belief_in_others stint 2 pool'),
  ('newtworks_v1_personality', 212,
   'Am indifferent to the feelings of others.',
   NULL, NULL, false, NULL, 'compassion', true, 5, 2, true,
   'Counterweight for negative-skew rebalance on compassion stint 2 pool'),
  ('newtworks_v1_personality', 213,
   'Have little sympathy for people who are worse off than me.',
   NULL, NULL, false, NULL, 'compassion', true, 5, 2, true,
   'Counterweight for negative-skew rebalance on compassion stint 2 pool'),
  ('newtworks_v1_personality', 214,
   'Feel restless when spending too much time alone.',
   NULL, NULL, false, NULL, 'independent_spirit', true, 5, 2, true,
   'Counterweight for negative-skew rebalance on independent_spirit stint 2 pool'),
  ('newtworks_v1_personality', 215,
   'Prefer working alongside others to working solo.',
   NULL, NULL, false, NULL, 'independent_spirit', true, 5, 2, true,
   'Counterweight for negative-skew rebalance on independent_spirit stint 2 pool'),
  ('newtworks_v1_personality', 216,
   'Am relaxed most of the time.',
   NULL, NULL, false, NULL, 'optimism', false, 5, 2, true,
   'Counterweight for positive-skew rebalance on optimism stint 2 pool'),
  ('newtworks_v1_personality', 217,
   'Recover quickly from setbacks.',
   NULL, NULL, false, NULL, 'optimism', false, 5, 2, true,
   'Counterweight for positive-skew rebalance on optimism stint 2 pool');
