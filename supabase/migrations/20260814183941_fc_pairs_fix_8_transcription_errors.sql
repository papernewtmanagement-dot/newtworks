-- Fix 8 rows where desirability values were mis-transcribed in migration fc_pairs_replace_with_measured_set
-- Values restored verbatim from the solver-verified source (checksum-diffed against DB)
UPDATE hiregauge_instrument_items i
SET choices = v.choices::jsonb, updated_at = now()
FROM (VALUES
 (526, '{"A": {"text": "I stay focused when plans change unexpectedly", "facet": "anxiety", "desirability": 7.67}, "B": {"text": "I keep tone level when a plan falls apart", "facet": "anger", "desirability": 7.67}}'),
 (551, '{"A": {"text": "I put in extra effort to reach a stretch goal", "facet": "achievement_striving", "desirability": 7.67}, "B": {"text": "I communicate in a genuine, straightforward way", "facet": "sincerity", "desirability": 7.67}}'),
 (566, '{"A": {"text": "I rely on coworkers to do their part", "facet": "trust", "desirability": 6.67}, "B": {"text": "I feel equipped to handle whatever the day brings", "facet": "self_efficacy", "desirability": 6.67}}'),
 (575, '{"A": {"text": "I base advice on the client''s needs rather than earnings", "facet": "greed_avoidance", "desirability": 8.0}, "B": {"text": "I apply rules consistently across the team", "facet": "fairness", "desirability": 8.0}}'),
 (578, '{"A": {"text": "I seek out challenging assignments over easy ones", "facet": "achievement_striving", "desirability": 7.33}, "B": {"text": "I trust my own ability to handle a tough situation", "facet": "self_efficacy", "desirability": 7.33}}'),
 (587, '{"A": {"text": "I set my sights on being the best in the office", "facet": "competitiveness", "desirability": 5.67}, "B": {"text": "I assume good intent behind a colleague''s actions", "facet": "trust", "desirability": 5.67}}'),
 (593, '{"A": {"text": "I propose new ventures when the timing is right", "facet": "enterprising", "desirability": 6.0}, "B": {"text": "I get energized by a head-to-head challenge", "facet": "competitiveness", "desirability": 6.33}}'),
 (595, '{"A": {"text": "I believe a teammate will follow through as promised", "facet": "trust", "desirability": 6.0}, "B": {"text": "I watch closely for signs of things going wrong", "facet": "avoid_goal_orientation", "desirability": 6.0}}')
) AS v(item_number, choices)
WHERE i.section='newtworks_v2_personality_fc' AND i.item_number = v.item_number;
