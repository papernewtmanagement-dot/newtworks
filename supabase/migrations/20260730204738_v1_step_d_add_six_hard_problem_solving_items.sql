-- Newtworks v1 cognitive — Step D
-- Add 6 hard problem-solving items to bring the problem_solving bank to 8 total.
-- Style matches existing items 52-53: hard word/reasoning problem, 5 choice options,
-- answer_key stored as the full choice text (not letter or index).
-- All items are stint 2 (adaptive-expansion pool) and active.

INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense, stint, is_active, cognitive_domain, notes)
VALUES
  ('cognitive', 61,
   'A recipe calls for flour and sugar in a ratio of 5 to 2. If a baker uses 15 cups of flour, how many cups of sugar are needed?',
   '["3 cups","5 cups","6 cups","7.5 cups","10 cups"]'::jsonb,
   '6 cups',
   false, 2, true, 'problem_solving',
   'newtworks_v1_cognitive | word_problem | hard | ratio proportion; 5:2 :: 15:x -> x = 15*2/5 = 6'),

  ('cognitive', 62,
   'A jacket originally priced at $80 is marked down 25 percent. During a sale, an additional 20 percent is taken off the discounted price. What is the final price?',
   '["$44","$48","$52","$56","$60"]'::jsonb,
   '$48',
   false, 2, true, 'problem_solving',
   'newtworks_v1_cognitive | word_problem | hard | compound discount; 80*0.75=60; 60*0.80=48'),

  ('cognitive', 63,
   'What number continues this sequence: 2, 6, 12, 20, 30, ...?',
   '["36","40","42","44","48"]'::jsonb,
   '42',
   false, 2, true, 'problem_solving',
   'newtworks_v1_cognitive | sequence | hard | second differences constant; +4,+6,+8,+10,+12 -> 30+12=42'),

  ('cognitive', 64,
   'Every student in Ms. Lee''s class plays a sport. Some sports players are on the debate team. No debate team member has a job. Which of the following must be true?',
   '["Every student in Ms. Lee''s class is on the debate team","No student in Ms. Lee''s class has a job","Some students in Ms. Lee''s class are on the debate team","Any student in Ms. Lee''s class who is on the debate team has no job","No student in Ms. Lee''s class plays a sport"]'::jsonb,
   'Any student in Ms. Lee''s class who is on the debate team has no job',
   false, 2, true, 'problem_solving',
   'newtworks_v1_cognitive | deductive_logic | hard | syllogism chain: Lee->sports, debate->no_job; therefore Lee-and-debate -> no_job'),

  ('cognitive', 65,
   'In a group of 50 people, 30 like coffee and 25 like tea. If 10 people like neither, how many like both?',
   '["5","10","15","20","25"]'::jsonb,
   '15',
   false, 2, true, 'problem_solving',
   'newtworks_v1_cognitive | set_logic | hard | inclusion-exclusion; 50-10=40 like at least one; 30+25-40=15 like both'),

  ('cognitive', 66,
   'Two trains start 200 miles apart moving toward each other. Train A moves at 40 mph, Train B moves at 60 mph. How long until they meet?',
   '["1 hour","1.5 hours","2 hours","2.5 hours","3 hours"]'::jsonb,
   '2 hours',
   false, 2, true, 'problem_solving',
   'newtworks_v1_cognitive | word_problem | hard | closing speed 100 mph; 200/100 = 2 hours');

-- Verify insert
SELECT item_number, cognitive_domain, is_active,
       LEFT(item_text, 60) || '...' AS preview
FROM public.hiregauge_instrument_items
WHERE section='cognitive' AND cognitive_domain='problem_solving'
ORDER BY item_number;
