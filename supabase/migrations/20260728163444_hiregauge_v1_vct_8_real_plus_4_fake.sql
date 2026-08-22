-- Newtworks v1 Stint 2 build, step 6 of 10 per handoff 2026-07-28.
--
-- Adds 12 vocabulary-check items to new section='newtworks_v1_vct':
--   8 real English words with graded difficulty (easy → very hard)
--   4 fabricated pseudo-words that do not exist in English
--
-- Validity mechanic: every item is multiple-choice with "None of these"
-- as the last option. Real words have a correct definition among the
-- first four choices. Fake words have four plausible-sounding but
-- fabricated definitions — the correct answer is always "None of these"
-- because the word itself is not real. Endorsing a fabricated definition
-- = "nonsense inflation" (either faking knowledge or careless clicking).
--
-- The step 8 expansion trigger nonsense_inflation fires when candidate
-- endorses ≥2 fake-word definitions. Stint=1 seed has exactly 2 fake
-- items so the trigger can fire on the primary sitting.
--
-- Stint distribution:
--   Stint 1 (6 items): 4 real (easy → medium) + 2 fake — primary check
--   Stint 2 (6 items): 4 real (medium-hard → very hard) + 2 fake —
--     expansion pool when IM or nonsense signals elevate
--
-- No hypothesized_trait (validity, not personality). No scale_max
-- (multiple choice, not Likert). No reverse_coded (multiple choice).

INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense,
   hypothesized_trait, reverse_coded, scale_max, stint, notes)
VALUES
  -- ==== STINT 1: 4 real (easy → medium) + 2 fake ====
  ('newtworks_v1_vct', 1,
   'What does the word "perimeter" mean?',
   '["the inner section of a shape","the outer boundary of a shape or area","the halfway point between two edges","the exact center","None of these"]'::jsonb,
   'the outer boundary of a shape or area',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_vct | real | easy'),

  ('newtworks_v1_vct', 2,
   'What does the word "frugal" mean?',
   '["wasteful with money","generous with gifts","careful with money and resources","fearful of new things","overly formal","None of these"]'::jsonb,
   'careful with money and resources',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_vct | real | easy-medium'),

  ('newtworks_v1_vct', 3,
   'What does the word "candid" mean?',
   '["sneaky and evasive","openly honest and direct","persistently sad","indifferent to outcomes","uncertain about details","None of these"]'::jsonb,
   'openly honest and direct',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_vct | real | medium'),

  ('newtworks_v1_vct', 4,
   'What does the word "ephemeral" mean?',
   '["permanent and lasting","extremely large in size","lasting only a short time","exceptionally complicated","done with clear purpose","None of these"]'::jsonb,
   'lasting only a short time',
   false, NULL, NULL, NULL, 1,
   'newtworks_v1_vct | real | medium'),

  ('newtworks_v1_vct', 5,
   'What does the word "klanther" mean?',
   '["a heavy wool cloak worn in the highlands","an old term for a decorative candlestick","a wading bird found in salt marshes","a small mountain pass between two ridges","None of these"]'::jsonb,
   'None of these',
   true, NULL, NULL, NULL, 1,
   'newtworks_v1_vct | fabricated | not a real English word; correct answer is None of these'),

  ('newtworks_v1_vct', 6,
   'What does the word "frebtulism" mean?',
   '["a philosophical stance on doubt","the scientific study of shellfish","an early form of parliamentary government","a rare skin condition","None of these"]'::jsonb,
   'None of these',
   true, NULL, NULL, NULL, 1,
   'newtworks_v1_vct | fabricated | not a real English word; correct answer is None of these'),

  -- ==== STINT 2: 4 real (medium-hard → very hard) + 2 fake ====
  ('newtworks_v1_vct', 7,
   'What does the word "meticulous" mean?',
   '["careless and rushed","habitually lazy","extremely careful about details","aggressively confrontational","excessively generous","None of these"]'::jsonb,
   'extremely careful about details',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_vct | real | medium-hard'),

  ('newtworks_v1_vct', 8,
   'What does the word "assiduous" mean?',
   '["lazy and disengaged","showing great care and persistent effort","openly contemptuous","aimless or wandering","actively harmful","None of these"]'::jsonb,
   'showing great care and persistent effort',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_vct | real | hard'),

  ('newtworks_v1_vct', 9,
   'What does the word "ubiquitous" mean?',
   '["one-of-a-kind","exceedingly rare","present everywhere","forbidden by law","ancient in origin","None of these"]'::jsonb,
   'present everywhere',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_vct | real | hard'),

  ('newtworks_v1_vct', 10,
   'What does the word "perfunctory" mean?',
   '["thorough and heartfelt","performed only as a routine, without real care","openly hostile","full of energy","official or formal","None of these"]'::jsonb,
   'performed only as a routine, without real care',
   false, NULL, NULL, NULL, 2,
   'newtworks_v1_vct | real | very hard'),

  ('newtworks_v1_vct', 11,
   'What does the word "prontivate" mean?',
   '["to argue a case in a scholarly manner","to gradually reduce in size","to promote or advance to a higher position","to sort items by category","None of these"]'::jsonb,
   'None of these',
   true, NULL, NULL, NULL, 2,
   'newtworks_v1_vct | fabricated | not a real English word; correct answer is None of these'),

  ('newtworks_v1_vct', 12,
   'What does the word "oblindous" mean?',
   '["difficult to see or perceive clearly","stubbornly persistent","richly ornamented","obviously deceitful","None of these"]'::jsonb,
   'None of these',
   true, NULL, NULL, NULL, 2,
   'newtworks_v1_vct | fabricated | not a real English word; correct answer is None of these');
