-- Replace the 18 un-sourced Newtworks v1 cognitive items (math + problem_solving
-- domains, hand-written with no published source) with 7 cited, validated,
-- public-domain items: 3 from the Cognitive Reflection Test (Frederick 2005,
-- Journal of Economic Perspectives 19(4), 25-42) and 4 from the Berlin
-- Numeracy Test multiple-choice format (Cokely, Galesic, Schulz, Ghazal &
-- Garcia-Retamero 2012, Judgment and Decision Making 7(1), 25-47; official
-- text sourced from riskliteracy.org, the test authors' own site).
--
-- Deactivate rather than delete: existing hiring_candidates rows may already
-- have hiregauge_candidate_responses tied to these item IDs (FK'd), and
-- compute_newtworks_v1_cognitive_score already filters on i.is_active, so
-- deactivating preserves historical scoring integrity for any candidate who
-- already took the old version.
--
-- Net item count for this slice drops from 18 to 7 (CRT is only 3 items,
-- BNT only 4 — neither pretends to be a full replacement, this trades volume
-- for having an actual citation and published psychometric properties).
UPDATE hiregauge_instrument_items
SET is_active = false, updated_at = now()
WHERE section = 'cognitive'
  AND cognitive_domain IN ('math', 'problem_solving');

INSERT INTO hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, cognitive_domain, stint, is_active, notes)
VALUES
  ('cognitive', 245,
   'A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?',
   NULL, '5', 'problem_solving', 1, true,
   'CRT item 1 of 3 (Frederick 2005, JEP 19(4), 25-42). Free-response, cents. Intuitive-but-wrong answer is 10.'),
  ('cognitive', 246,
   'If it takes 5 machines 5 minutes to make 5 widgets, how long would it take 100 machines to make 100 widgets?',
   NULL, '5', 'problem_solving', 1, true,
   'CRT item 2 of 3 (Frederick 2005). Free-response, minutes. Intuitive-but-wrong answer is 100.'),
  ('cognitive', 247,
   'In a lake, there is a patch of lily pads. Every day, the patch doubles in size. If it takes 48 days for the patch to cover the entire lake, how long would it take for the patch to cover half of the lake?',
   NULL, '47', 'problem_solving', 1, true,
   'CRT item 3 of 3 (Frederick 2005). Free-response, days. Intuitive-but-wrong answer is 24.'),
  ('cognitive', 248,
   'Imagine we are throwing a five-sided die 50 times. On average, out of these 50 throws how many times would this five-sided die show an odd number (1, 3, or 5)?',
   '["5 out of 50 throws", "25 out of 50 throws", "30 out of 50 throws", "None of the above"]', '30 out of 50 throws', 'math', 1, true,
   'Berlin Numeracy Test item 1 of 4, multiple-choice format (Cokely et al. 2012, JDM 7(1), 25-47; text via riskliteracy.org).'),
  ('cognitive', 249,
   'Out of 1,000 people in a small town, 500 are members of a choir. Out of these 500 members in the choir, 100 are men. Out of the 500 inhabitants that are not in the choir, 300 are men. What is the probability that a randomly drawn man is a member of the choir?',
   '["10%", "25%", "40%", "None of the above"]', '25%', 'math', 1, true,
   'Berlin Numeracy Test item 2 of 4, multiple-choice format (Cokely et al. 2012).'),
  ('cognitive', 250,
   'Imagine we are throwing a loaded die (6 sides). The probability that the die shows a 6 is twice as high as the probability of each of the other numbers. On average, out of these 70 throws, about how many times would the die show the number 6?',
   '["20 out of 70 throws", "23 out of 70 throws", "35 out of 70 throws", "None of the above"]', '20 out of 70 throws', 'math', 1, true,
   'Berlin Numeracy Test item 3 of 4, multiple-choice format (Cokely et al. 2012).'),
  ('cognitive', 251,
   'In a forest, 20% of mushrooms are red, 50% brown, and 30% white. A red mushroom is poisonous with a probability of 20%. A mushroom that is not red is poisonous with a probability of 5%. What is the probability that a poisonous mushroom in the forest is red?',
   '["4%", "20%", "50%", "None of the above"]', '50%', 'math', 1, true,
   'Berlin Numeracy Test item 4 of 4, multiple-choice format (Cokely et al. 2012).');
