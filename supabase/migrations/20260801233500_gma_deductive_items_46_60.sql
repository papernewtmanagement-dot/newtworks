-- GMA deductive-reasoning items 46-60 (15 items) -- third of 4 planned GMA
-- subtests (pattern-matching 1-30, numerical 31-45, deductive here, verbal
-- remains). Shares newtworks_v2_cognitive_gma section, continues item_number
-- from 46. Uses the EXISTING generic multi-choice renderer (choices is a
-- plain 3-option JSONB array, same shape as SJT/VCT items) -- no new
-- frontend component needed.
--
-- VALIDITY NOT HAND-JUDGED: every answer_key is the output of a brute-force
-- finite-model checker (exhaustive over a 4-element universe, 4096 models)
-- in /home/claude/gma_ded/generate_deductive.py. Abstract nonsense-word
-- category labels avoid "belief bias" (Evans, Newstead & Byrne 1993).
-- Classical syllogism background: Copi & Cohen, Introduction to Logic
-- (11th ed.) -- but the checker is the actual authority for each item.
--
-- Answer distribution deliberately balanced 5/5/5 across the three response
-- options so the test cannot be gamed by always picking one answer.
--
-- is_active=false, stint=0 -- same placeholder convention as every other
-- v2 item.

INSERT INTO hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, cognitive_domain, stint, is_active)
VALUES
(
  'newtworks_v2_cognitive_gma', 46, 'All Vindaro are Kelbit. No Kelbit are Tarnum. Given only this, consider the statement: "No Vindaro are Tarnum." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It must be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 47, 'All Blenthar are Orvix. All Orvix are Sammel. Given only this, consider the statement: "All Blenthar are Sammel." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It must be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 48, 'Some Quorlin are Dresta. No Dresta are Halvox. Given only this, consider the statement: "Some Quorlin are not Halvox." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It must be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 49, 'Some Prindel are Wexara. All Wexara are Norbit. Given only this, consider the statement: "Some Prindel are Norbit." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It must be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 50, 'Some Farlin are Ostrey. All Ostrey are Culmax. Given only this, consider the statement: "Some Farlin are Culmax." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It must be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 51, 'All Trebond are Yulara. All Yulara are Mensiko. Given only this, consider the statement: "Some Trebond are not Mensiko." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It cannot be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 52, 'All Kestrel-form are Voltane. No Voltane are Ibrina. Given only this, consider the statement: "Some Kestrel-form are Ibrina." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It cannot be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 53, 'Some Zendrick are Pallux. All Pallux are Ravorn. Given only this, consider the statement: "No Zendrick are Ravorn." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It cannot be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 54, 'Some Drennow are Sylvex. No Sylvex are Camrith. Given only this, consider the statement: "All Drennow are Camrith." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It cannot be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 55, 'Some Untra are Belmark. No Belmark are Fosgen. Given only this, consider the statement: "All Untra are Fosgen." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It cannot be true.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 56, 'All Ranthol are Widget-class. No Widget-class are Corvale. Given only this, consider the statement: "All Ranthol are Corvale." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It''s impossible to tell from the information given.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 57, 'Some Malren are Ostwick. All Ostwick are Tavenor. Given only this, consider the statement: "All Malren are Tavenor." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It''s impossible to tell from the information given.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 58, 'All Corvid-set are Halbern. Some Halbern are Nyxara. Given only this, consider the statement: "Some Corvid-set are not Nyxara." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It''s impossible to tell from the information given.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 59, 'Some Prendel are Vostrik. Some Vostrik are not Lammar. Given only this, consider the statement: "Some Prendel are Lammar." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It''s impossible to tell from the information given.', 'gma_deductive', 0, false
),
(
  'newtworks_v2_cognitive_gma', 60, 'Some Bexley-group are Quintar. Some Quintar are Ferrow. Given only this, consider the statement: "Some Bexley-group are not Ferrow." What do you know about that statement?',
  '["It must be true.", "It cannot be true.", "It''s impossible to tell from the information given."]'::jsonb, 'It''s impossible to tell from the information given.', 'gma_deductive', 0, false
);

