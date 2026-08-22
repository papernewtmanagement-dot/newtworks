-- Content expansion for v1 assessment baseline + retest coverage.
-- (item_number, section) is UNIQUE across stints, so stint=2 retest items
-- extend the existing 200-204 range from stint=1 rather than reusing it.

-- Part 1: stint=2 retest items (item_numbers 205-207 continue past stint=1 200-204)
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense,
   retest_of_item_number, hypothesized_trait, reverse_coded, scale_max, stint, is_active, notes)
VALUES
  ('newtworks_v1_personality', 205,
   'Take an interest in other people''s lives.',
   NULL, NULL, false,
   4, 'compassion', false, 7, 2, true,
   'Stint=2 retest of stint=1 item 4 for cross-stint consistency check'),
  ('newtworks_v1_personality', 206,
   'Get chores done right away.',
   NULL, NULL, false,
   95, 'deadline_motivation', false, 7, 2, true,
   'Stint=2 retest of stint=1 item 95 for cross-stint consistency check'),
  ('newtworks_v1_personality', 207,
   'Enjoy spending time by myself.',
   NULL, NULL, false,
   86, 'independent_spirit', false, 7, 2, true,
   'Stint=2 retest of stint=1 item 86 for cross-stint consistency check');

-- Part 2: 7 new stint=1 cognitive items (item_numbers 54-60 continue past 36-53)
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense,
   retest_of_item_number, hypothesized_trait, reverse_coded, scale_max, stint, is_active, notes)
VALUES
  ('cognitive', 54,
   'In the following number series, what number comes next? 5, 10, 15, 20, ?',
   '["22","23","25","30","35"]'::jsonb, '25', false,
   NULL, NULL, NULL, NULL, 1, true,
   'Arithmetic +5 progression, entry level'),
  ('cognitive', 55,
   'In the following number series, what number comes next? 3, 6, 9, 12, ?',
   '["13","14","15","16","18"]'::jsonb, '15', false,
   NULL, NULL, NULL, NULL, 1, true,
   'Arithmetic +3 progression, entry level'),
  ('cognitive', 56,
   'In the following letter series, what letter comes next? M, N, O, P, ?',
   '["Q","R","S","T","U"]'::jsonb, 'Q', false,
   NULL, NULL, NULL, NULL, 1, true,
   'Consecutive letter progression, entry level'),
  ('cognitive', 57,
   'In the following letter series, what letter comes next? J, H, F, D, ?',
   '["A","B","C","E","G"]'::jsonb, 'B', false,
   NULL, NULL, NULL, NULL, 1, true,
   'Skip-one backward letter progression, entry level'),
  ('cognitive', 58,
   'Book is to read as song is to ?',
   '["cover","author","listen","page","melody"]'::jsonb, 'listen', false,
   NULL, NULL, NULL, NULL, 1, true,
   'Verbal analogy — object-to-action pairing'),
  ('cognitive', 59,
   'Chef is to kitchen as pilot is to ?',
   '["airplane","cockpit","airport","runway","sky"]'::jsonb, 'cockpit', false,
   NULL, NULL, NULL, NULL, 1, true,
   'Verbal analogy — worker-to-workplace pairing'),
  ('cognitive', 60,
   'If 3 apples cost $6, how much do 5 apples cost?',
   '["$8","$9","$10","$12","$15"]'::jsonb, '$10', false,
   NULL, NULL, NULL, NULL, 1, true,
   'Ratio word problem, entry level');
