-- Newtworks v1 Stint 2 build, step 4 of 10 per handoff 2026-07-28.
--
-- Adds 18 custom cognitive items to section='cognitive'. ICAR items were
-- ruled out at Peter's direction 2026-07-28 due to their Sharing Level 1
-- (Scientific Use) license on PsychArchives — the maintainers do not
-- release items + scoring keys for production hiring use.
--
-- Items authored in-house across 4 psychometric templates:
--   • Number series (5): arithmetic, geometric, squares, doubling+1, factorial
--   • Letter series (5): sequential, skip-one, reverse skip, position-squared,
--                        even-differences
--   • Verbal analogies (4): concrete-relation + antonym-pair patterns
--   • Word problems (4): unit rate, percent, machine-hours, mixed-speed
--
-- Difficulty gradient runs easy → hard within each type. Stint=1 (8 items)
-- serves a balanced easy/medium sample to every candidate; stint=2 (10
-- items, harder-skewed) is the pool the borderline_cognitive expansion
-- rule (40-60 score) draws +5 from.
--
-- All items multi-choice, 5 options each, no scale_max (Likert-only field).
-- No CTS cognitive item is touched; those are stint=NULL and will filter
-- out of v1 scoring by stint IN (1,2) clause naturally.

INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense,
   hypothesized_trait, reverse_coded, scale_max, stint, notes)
VALUES
  -- ==== NUMBER SERIES ====
  ('cognitive', 36,
   'In the following number series, what number comes next? 2, 4, 6, 8, ?',
   '["9","10","11","12","14"]'::jsonb, '10',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_cognitive | number_series | easy | arithmetic +2'),

  ('cognitive', 37,
   'In the following number series, what number comes next? 3, 6, 12, 24, ?',
   '["36","42","48","60","96"]'::jsonb, '48',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | number_series | easy-medium | geometric ×2'),

  ('cognitive', 38,
   'In the following number series, what number comes next? 1, 4, 9, 16, ?',
   '["20","24","25","30","36"]'::jsonb, '25',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_cognitive | number_series | medium | perfect squares'),

  ('cognitive', 39,
   'In the following number series, what number comes next? 2, 5, 11, 23, ?',
   '["35","43","45","47","51"]'::jsonb, '47',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | number_series | medium-hard | each term = 2×prev + 1'),

  ('cognitive', 40,
   'In the following number series, what number comes next? 1, 2, 6, 24, ?',
   '["96","100","120","144","150"]'::jsonb, '120',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | number_series | hard | factorials 1! 2! 3! 4! 5!'),

  -- ==== LETTER SERIES ====
  ('cognitive', 41,
   'In the following letter series, what letter comes next? A, B, C, D, ?',
   '["E","F","G","H","I"]'::jsonb, 'E',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_cognitive | letter_series | easy | sequential'),

  ('cognitive', 42,
   'In the following letter series, what letter comes next? A, C, E, G, ?',
   '["H","I","J","K","L"]'::jsonb, 'I',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | letter_series | easy-medium | skip one forward'),

  ('cognitive', 43,
   'In the following letter series, what letter comes next? Z, X, V, T, ?',
   '["P","Q","R","S","U"]'::jsonb, 'R',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_cognitive | letter_series | medium | skip one backward'),

  ('cognitive', 44,
   'In the following letter series, what letter comes next? A, D, I, P, ?',
   '["T","V","W","X","Y"]'::jsonb, 'Y',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | letter_series | medium-hard | positions are perfect squares 1 4 9 16 25'),

  ('cognitive', 45,
   'In the following letter series, what letter comes next? B, D, H, N, ?',
   '["R","T","V","X","Z"]'::jsonb, 'V',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | letter_series | hard | position differences +2 +4 +6 +8'),

  -- ==== VERBAL ANALOGIES ====
  ('cognitive', 46,
   'Bird is to fly as fish is to ?',
   '["water","swim","ocean","gill","scale"]'::jsonb, 'swim',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_cognitive | analogy | moderate | animal-to-locomotion'),

  ('cognitive', 47,
   'Doctor is to hospital as teacher is to ?',
   '["school","classroom","student","education","textbook"]'::jsonb, 'school',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_cognitive | analogy | moderate | worker-to-workplace'),

  ('cognitive', 48,
   'Novice is to expert as apprentice is to ?',
   '["student","master","teacher","professional","supervisor"]'::jsonb, 'master',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | analogy | hard | beginner-to-endpoint pair on skill progression'),

  ('cognitive', 49,
   'Frugal is to spendthrift as courageous is to ?',
   '["brave","cowardly","careful","hostile","reckless"]'::jsonb, 'cowardly',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | analogy | hard | antonym-of-virtue pair; distractor "brave" is synonym trap'),

  -- ==== WORD PROBLEMS ====
  ('cognitive', 50,
   'If 4 pens cost $8, how much do 7 pens cost?',
   '["$12","$14","$16","$18","$21"]'::jsonb, '$14',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_cognitive | word_problem | easy | unit rate × 7'),

  ('cognitive', 51,
   'A shirt is on sale for 25% off. If the sale price is $30, what was the original price?',
   '["$35","$37.50","$40","$45","$50"]'::jsonb, '$40',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_cognitive | word_problem | medium | reverse percent; distractor $37.50 is +25% of $30 (naive trap)'),

  ('cognitive', 52,
   'If it takes 6 machines 12 hours to produce 100 widgets, how long would it take 4 machines to produce 100 widgets (assuming the same rate per machine)?',
   '["8 hours","16 hours","18 hours","24 hours","72 hours"]'::jsonb, '18 hours',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | word_problem | hard | inverse proportion 6×12=72 machine-hours; 72÷4=18'),

  ('cognitive', 53,
   'A car travels 60 miles in 1 hour going uphill and 90 miles in 1 hour going downhill. If it goes uphill for 30 minutes and downhill for 40 minutes, how far does it travel in total?',
   '["80 miles","85 miles","90 miles","95 miles","100 miles"]'::jsonb, '90 miles',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_cognitive | word_problem | hard | mixed rates; 60×0.5 + 90×(40/60) = 30 + 60 = 90');
