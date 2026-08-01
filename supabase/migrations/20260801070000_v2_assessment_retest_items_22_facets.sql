-- v2 assessment retest items: 1 per personality facet (22 facets; Perseverance
-- excluded, it has no separate item pool, routed to self_discipline per locked
-- operational_rule). Verbatim repeat of a mid-block source item per facet,
-- per Meade & Craig 2012 within-sitting careless-responding detection
-- methodology (locked operational_rule "retest_positioning": 15-20 items after
-- original in the SAME stint, not days-apart).
INSERT INTO hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, scale_max, stint,
   hypothesized_trait, reverse_coded, retest_of_item_number, is_active)
VALUES
  ('newtworks_v2_personality', 223, 'I''m always optimistic about my future.', NULL, NULL, 5, 2, 'dispositional_optimism', false, 3, true),
  ('newtworks_v2_personality', 224, 'Switch my loyalties when I feel like it.', NULL, NULL, 5, 1, 'sincerity', true, 11, true),
  ('newtworks_v2_personality', 225, 'Try to follow the rules.', NULL, NULL, 5, 1, 'fairness', false, 21, true),
  ('newtworks_v2_personality', 226, 'Seek status.', NULL, NULL, 5, 1, 'greed_avoidance', true, 31, true),
  ('newtworks_v2_personality', 227, 'Take control of things.', NULL, NULL, 5, 2, 'assertiveness', false, 41, true),
  ('newtworks_v2_personality', 228, 'Make people feel at ease.', NULL, NULL, 5, 2, 'compassion', false, 52, true),
  ('newtworks_v2_personality', 229, 'Thanks to my resourcefulness, I know how to handle unforeseen situations.', NULL, NULL, 4, 2, 'self_efficacy', false, 63, true),
  ('newtworks_v2_personality', 230, 'No matter what the odds, if I believe in something I will make it happen.', NULL, NULL, 7, 2, 'proactive_personality', false, 73, true),
  ('newtworks_v2_personality', 231, 'I have developed a large network of colleagues and associates at work who I can call on for support when I really need to get things done.', NULL, NULL, 7, 2, 'political_skill_networking', false, 81, true),
  ('newtworks_v2_personality', 232, 'I try to figure out what a customer''s needs are.', NULL, NULL, 9, 2, 'customer_orientation', false, 96, true),
  ('newtworks_v2_personality', 233, 'Operate a beauty salon or barber shop', NULL, NULL, 5, 2, 'enterprising', false, 113, true),
  ('newtworks_v2_personality', 234, 'Get caught up in my problems.', NULL, NULL, 5, 2, 'anxiety', false, 123, true),
  ('newtworks_v2_personality', 235, 'Lose my temper.', NULL, NULL, 5, 2, 'anger', false, 133, true),
  ('newtworks_v2_personality', 236, 'Believe in human goodness.', NULL, NULL, 5, 2, 'trust', false, 143, true),
  ('newtworks_v2_personality', 237, 'Contradict others.', NULL, NULL, 5, 2, 'cooperation', true, 153, true),
  ('newtworks_v2_personality', 238, 'Cheer people up.', NULL, NULL, 5, 2, 'friendliness', false, 163, true),
  ('newtworks_v2_personality', 239, 'Listen to my conscience.', NULL, NULL, 5, 2, 'dutifulness', false, 173, true),
  ('newtworks_v2_personality', 240, 'Do more than what''s expected of me.', NULL, NULL, 5, 2, 'achievement_striving', false, 183, true),
  ('newtworks_v2_personality', 241, 'Carry out my plans.', NULL, NULL, 5, 2, 'self_discipline', false, 193, true),
  ('newtworks_v2_personality', 242, 'Make rash decisions.', NULL, NULL, 5, 2, 'cautiousness', true, 203, true),
  ('newtworks_v2_personality', 243, 'Panic easily.', NULL, NULL, 5, 2, 'emotional_stability', true, 213, true),
  ('newtworks_v2_personality', 244, 'Do most of the talking.', NULL, NULL, 5, 2, 'assured_dominance', false, 220, true);
