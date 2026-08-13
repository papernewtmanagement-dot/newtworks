-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 23:23:08 UTC (ledger name: v2_assessment_vocabulary_check_full_16) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801232308.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Vocabulary check, stint 2, 16 items total per spec. First 8 ported
-- unchanged from newtworks_v1_vct real-word items. Second 8 newly written
-- 2026-08-01, same format (multiple-choice definition, plausible wrong
-- distractors, "None of these" trailing option), continuing the existing
-- easy-to-very-hard difficulty spread. No published-instrument citation
-- applies here -- this is a home-grown vocabulary/attention item type, not
-- drawn from a validated psychometric scale, matching the existing v1
-- pattern exactly.

-- Port the 8 existing real words
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, stint, item_text, choices, scale_max, is_nonsense, answer_key, is_active, notes)
SELECT
  'newtworks_v2_personality', 332 + item_number, 2,
  item_text, choices, scale_max, is_nonsense, answer_key, true,
  notes || ' | Ported from newtworks_v1_vct item ' || item_number || ' to v2 2026-08-01 (vocabulary check, Path A self-contained v2 flow).'
FROM public.hiregauge_instrument_items
WHERE section = 'newtworks_v1_vct' AND is_nonsense = false;

-- 8 newly written words to reach 16 total
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, stint, item_text, choices, scale_max, is_nonsense, answer_key, is_active, notes)
VALUES
  ('newtworks_v2_personality', 350, 2,
   'What does the word "diligent" mean?',
   '["quick to anger","indifferent to outcomes","showing steady, careful effort in one''s work","prone to daydreaming","excessively cautious","None of these"]',
   NULL, false, 'showing steady, careful effort in one''s work', true,
   'newtworks_v2_vocab_check | real | easy | written 2026-08-01, no published-instrument citation applies (home-grown item type, matches v1 vct pattern)'),
  ('newtworks_v2_personality', 351, 2,
   'What does the word "pragmatic" mean?',
   '["overly idealistic","dealing with things in a sensible, practical way","impossible to please","secretive by nature","quick to give up","None of these"]',
   NULL, false, 'dealing with things in a sensible, practical way', true,
   'newtworks_v2_vocab_check | real | easy-medium | written 2026-08-01, no published-instrument citation applies'),
  ('newtworks_v2_personality', 352, 2,
   'What does the word "ambiguous" mean?',
   '["completely certain","extremely detailed","open to more than one interpretation; unclear","publicly stated","financially sound","None of these"]',
   NULL, false, 'open to more than one interpretation; unclear', true,
   'newtworks_v2_vocab_check | real | medium | written 2026-08-01, no published-instrument citation applies'),
  ('newtworks_v2_personality', 353, 2,
   'What does the word "tenacious" mean?',
   '["easily discouraged","highly forgetful","holding firmly to a purpose; persistent","openly dishonest","socially withdrawn","None of these"]',
   NULL, false, 'holding firmly to a purpose; persistent', true,
   'newtworks_v2_vocab_check | real | medium | written 2026-08-01, no published-instrument citation applies'),
  ('newtworks_v2_personality', 354, 2,
   'What does the word "arbitrary" mean?',
   '["carefully calculated","legally required","widely accepted","based on random choice or personal whim rather than reason","extremely rare","None of these"]',
   NULL, false, 'based on random choice or personal whim rather than reason', true,
   'newtworks_v2_vocab_check | real | medium-hard | written 2026-08-01, no published-instrument citation applies'),
  ('newtworks_v2_personality', 355, 2,
   'What does the word "cogent" mean?',
   '["confusing and disorganized","emotionally manipulative","unnecessarily long","clear, logical, and convincing","based on rumor","None of these"]',
   NULL, false, 'clear, logical, and convincing', true,
   'newtworks_v2_vocab_check | real | hard | written 2026-08-01, no published-instrument citation applies'),
  ('newtworks_v2_personality', 356, 2,
   'What does the word "obsequious" mean?',
   '["openly rebellious","coldly indifferent","highly competitive","excessively eager to please or obey someone","quick to criticize","None of these"]',
   NULL, false, 'excessively eager to please or obey someone', true,
   'newtworks_v2_vocab_check | real | hard | written 2026-08-01, no published-instrument citation applies'),
  ('newtworks_v2_personality', 357, 2,
   'What does the word "perspicacious" mean?',
   '["easily confused","overly talkative","prone to exaggeration","resistant to change","having keen insight and good judgment","None of these"]',
   NULL, false, 'having keen insight and good judgment', true,
   'newtworks_v2_vocab_check | real | very hard | written 2026-08-01, no published-instrument citation applies');

SELECT count(*) AS vocab_check_total FROM public.hiregauge_instrument_items
WHERE section = 'newtworks_v2_personality' AND item_number BETWEEN 333 AND 357;
