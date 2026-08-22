-- Adds the written screen ("Part 2") to the live assessment as Stint 5,
-- in-app, right after the SJT (Stint 4). Replaces the emailed Part 2 flow
-- from Hiring Prep manual (298250df-7ec2-4d6d-b500-ca5068ed4772).
-- 7 items, trimmed 2026-08-05: 5 free-text, 2 forced-choice gates.
-- Peter decision 2026-08-05: unaided writing is not a signal anymore
-- (~65-78% of candidates use AI on written application material per
-- 2025-2026 market data), so these are scored for substance/gates only,
-- never for writing quality.

ALTER TABLE hiregauge_instrument_items
  DROP CONSTRAINT hiregauge_instrument_items_section_check;

ALTER TABLE hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY[
    'instructions','vct','cognitive','cts',
    'newtworks_v1_personality','newtworks_v1_impression_mgmt','newtworks_v1_vct',
    'newtworks_v2_personality','newtworks_v2_cognitive_gma','newtworks_v2_impression_mgmt',
    'newtworks_v2_vct','newtworks_v2_sjt','newtworks_v2_screen'
  ]::text[]));

ALTER TABLE hiregauge_instrument_items
  ADD COLUMN IF NOT EXISTS response_format text;

ALTER TABLE hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_response_format_check
  CHECK (response_format IS NULL OR response_format = 'free_text');

INSERT INTO hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, response_format, stint, is_active)
VALUES
  ('newtworks_v2_screen', 1,
   'Why did you leave each job on your resume, and why are you leaving your current job (if applicable)?',
   NULL, NULL, 'free_text', 5, true),
  ('newtworks_v2_screen', 2,
   'What caused you to have an interest in this job?',
   NULL, NULL, 'free_text', 5, true),
  ('newtworks_v2_screen', 3,
   'What do you think will be the greatest challenges of this job?',
   NULL, NULL, 'free_text', 5, true),
  ('newtworks_v2_screen', 4,
   'Which compensation structure do you desire?',
   '["A lower base where I can earn more if I sell more", "A higher base where my overall pay is more predictable"]'::jsonb,
   'A lower base where I can earn more if I sell more',
   NULL, 5, true),
  ('newtworks_v2_screen', 5,
   'Tell us about a time when something went wrong because of a decision you made. What did you do to correct it? What should you have done differently?',
   NULL, NULL, 'free_text', 5, true),
  ('newtworks_v2_screen', 6,
   'If you come to work for us, are you willing to move all of your insurance products to our agency?',
   '["Yes", "No"]'::jsonb,
   'Yes',
   NULL, 5, true),
  ('newtworks_v2_screen', 7,
   'Please give us the name of a previous employer who will take our call to validate your answers above.',
   NULL, NULL, 'free_text', 5, true);

