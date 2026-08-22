-- Adds 11 more cited, validated, public-domain cognitive items on top of the
-- 7 shipped in migration 20260801080000 (3 CRT + 4 BNT), bringing this slice
-- back to 18 items total -- same count as before, but now every item traces
-- to a published, citable source instead of being hand-written with no
-- provenance. None of this is labeled ICAR anywhere (per Peter directive
-- 2026-08-01) and none of it touches the v2 ICAR-16 columns/section.
INSERT INTO hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, cognitive_domain, stint, is_active, notes)
VALUES
  ('cognitive', 252,
   'If you''re running a race and you pass the person in second place, what place are you in?',
   NULL, 'second', 'problem_solving', 1, true,
   'CRT-2 item 1 of 4 (Thomson & Oppenheimer 2016, JDM 11(1), 99-113). Free-response. Intuitive-but-wrong answer is first.'),
  ('cognitive', 253,
   'A farmer had 15 sheep and all but 8 died. How many are left?',
   NULL, '8', 'problem_solving', 1, true,
   'CRT-2 item 2 of 4 (Thomson & Oppenheimer 2016). Free-response. Intuitive-but-wrong answer is 7.'),
  ('cognitive', 254,
   'Emily''s father has three daughters. The first two are named April and May. What is the third daughter''s name?',
   NULL, 'Emily', 'problem_solving', 1, true,
   'CRT-2 item 3 of 4 (Thomson & Oppenheimer 2016). Free-response. Intuitive-but-wrong answer is June.'),
  ('cognitive', 255,
   'How many cubic feet of dirt are there in a hole that is 3 feet deep by 3 feet wide by 3 feet long?',
   NULL, '0', 'problem_solving', 1, true,
   'CRT-2 item 4 of 4 (Thomson & Oppenheimer 2016). Free-response, cubic feet. Intuitive-but-wrong answer is 27 (a hole has no dirt in it).'),
  ('cognitive', 256,
   'Imagine that we flip a fair coin 1,000 times. What is your best guess about how many times the coin would come up heads in 1,000 flips?',
   NULL, '500', 'math', 1, true,
   'Schwartz et al. 1997 numeracy item 1 of 3. Free-response, number of flips.'),
  ('cognitive', 257,
   'In the BIG BUCKS LOTTERY, the chance of winning a $10 prize is 1%. What is your best guess about how many people would win a $10 prize if 1,000 people each buy a single ticket to BIG BUCKS?',
   NULL, '10', 'math', 1, true,
   'Schwartz et al. 1997 numeracy item 2 of 3. Free-response, number of people.'),
  ('cognitive', 258,
   'In ACME PUBLISHING SWEEPSTAKES, the chance of winning a car is 1 in 1,000. What percent of tickets to ACME PUBLISHING SWEEPSTAKES win a car?',
   NULL, '0.1%', 'math', 1, true,
   'Schwartz et al. 1997 numeracy item 3 of 3. Free-response, percent.'),
  ('cognitive', 259,
   'Imagine that we roll a fair, six-sided die 1,000 times. Out of 1,000 rolls, how many times do you think the die would come up as an even number?',
   '["300", "167", "150", "500"]', '500', 'math', 1, true,
   'Weller et al. 2013 Abbreviated Numeracy Scale item (die/even-number). Multiple choice, text verified via secondary citation quoting exact wording and options.'),
  ('cognitive', 260,
   'In a lottery, the chance of winning a car is 1 in 1,000. What percentage of tickets in that lottery wins a car?',
   '["0.1%", "1%", "10%", "0.5%"]', '0.1%', 'math', 1, true,
   'Weller et al. 2013 Abbreviated Numeracy Scale item (lottery percentage). Multiple choice.'),
  ('cognitive', 261,
   'If the chance of getting a disease is 20 out of 100, this would be the same as having ____ chance of getting the disease.',
   '["80%", "2%", "20%", "40%"]', '20%', 'math', 1, true,
   'Weller et al. 2013 Abbreviated Numeracy Scale item (fraction-to-percent conversion). Multiple choice.'),
  ('cognitive', 262,
   'A notebook and a pen cost 1.80 euros in total. The notebook costs 1.00 euro more than the pen. How much does the pen cost?',
   '["0.80 euros", "0.40 euros", "0.20 euros", "1.00 euros"]', '0.40 euros', 'math', 1, true,
   'Weller et al. 2013 Abbreviated Numeracy Scale item -- euro-denominated isomorph of the bat-and-ball problem, distinct wording from the CRT original already shipped as item 245. Multiple choice.');
