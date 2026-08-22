-- v2 assessment: duplicate v1 Assertiveness + Compassion items into newtworks_v2_personality section
-- per operational_rule "Newtworks v1 assessment v2 build" Path A doctrine + session 3 architecture lock option (a).
--
-- Assertiveness: 10 base items (v1 items 24-33). 6 positive / 4 reverse.
-- Compassion: 12 items (v1 items 1-10 base + v1 items 212, 213 stint-2 counterweights). 7 positive / 5 reverse.
-- Retest items (v1 201, v1 205) NOT duplicated — retest ingest tracked under OQ 0ba6edfe.
-- All v2 items assigned Stint 2 (personality baseline per v2 3-stint architecture).

INSERT INTO public.hiregauge_instrument_items (
  section, item_number, hypothesized_trait, item_text, reverse_coded, scale_max, stint, choices, notes
) VALUES
-- Assertiveness (10 items, v1 24-33 → v2 37-46)
('newtworks_v2_personality', 37, 'assertiveness', 'Take charge.',                                    false, 5, 2, NULL, 'v1 dup: assertiveness item 24. IPIP Assertiveness +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 38, 'assertiveness', 'Want to be in charge.',                           false, 5, 2, NULL, 'v1 dup: assertiveness item 25. IPIP Assertiveness +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 39, 'assertiveness', 'Say what I think.',                               false, 5, 2, NULL, 'v1 dup: assertiveness item 26. IPIP Assertiveness +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 40, 'assertiveness', 'Am not afraid of providing criticism.',           false, 5, 2, NULL, 'v1 dup: assertiveness item 27. IPIP Assertiveness +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 41, 'assertiveness', 'Take control of things.',                         false, 5, 2, NULL, 'v1 dup: assertiveness item 28. IPIP Assertiveness +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 42, 'assertiveness', 'Can take strong measures.',                       false, 5, 2, NULL, 'v1 dup: assertiveness item 29. IPIP Assertiveness +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 43, 'assertiveness', 'Wait for others to lead the way.',               true,  5, 2, NULL, 'v1 dup: assertiveness item 30. IPIP Assertiveness -keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 44, 'assertiveness', 'Never challenge things.',                         true,  5, 2, NULL, 'v1 dup: assertiveness item 31. IPIP Assertiveness -keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 45, 'assertiveness', 'Let others make the decisions.',                  true,  5, 2, NULL, 'v1 dup: assertiveness item 32. IPIP Assertiveness -keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 46, 'assertiveness', 'Let myself be pushed around.',                    true,  5, 2, NULL, 'v1 dup: assertiveness item 33. IPIP Assertiveness -keyed. Path A self-contained v2 flow.'),
-- Compassion (12 items: v1 1-10 base + v1 212, 213 counterweights → v2 47-58)
('newtworks_v2_personality', 47, 'compassion', 'Know how to comfort others.',                        false, 5, 2, NULL, 'v1 dup: compassion item 1. IPIP Warmth +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 48, 'compassion', 'Enjoy bringing people together.',                    false, 5, 2, NULL, 'v1 dup: compassion item 2. IPIP Warmth +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 49, 'compassion', 'Feel others'' emotions.',                            false, 5, 2, NULL, 'v1 dup: compassion item 3. IPIP Warmth +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 50, 'compassion', 'Take an interest in other people''s lives.',        false, 5, 2, NULL, 'v1 dup: compassion item 4. IPIP Warmth +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 51, 'compassion', 'Cheer people up.',                                   false, 5, 2, NULL, 'v1 dup: compassion item 5. IPIP Warmth +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 52, 'compassion', 'Make people feel at ease.',                          false, 5, 2, NULL, 'v1 dup: compassion item 6. IPIP Warmth +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 53, 'compassion', 'Take time out for others.',                          false, 5, 2, NULL, 'v1 dup: compassion item 7. IPIP Warmth +keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 54, 'compassion', 'Don''t like to get involved in other people''s problems.', true, 5, 2, NULL, 'v1 dup: compassion item 8. IPIP Warmth -keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 55, 'compassion', 'Am not really interested in others.',              true,  5, 2, NULL, 'v1 dup: compassion item 9. IPIP Warmth -keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 56, 'compassion', 'Try not to think about the needy.',                  true,  5, 2, NULL, 'v1 dup: compassion item 10. IPIP Warmth -keyed. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 57, 'compassion', 'Am indifferent to the feelings of others.',          true,  5, 2, NULL, 'v1 dup: compassion item 212. -keyed counterweight for stint 2 negative-skew rebalance. Path A self-contained v2 flow.'),
('newtworks_v2_personality', 58, 'compassion', 'Have little sympathy for people who are worse off than me.', true, 5, 2, NULL, 'v1 dup: compassion item 213. -keyed counterweight for stint 2 negative-skew rebalance. Path A self-contained v2 flow.');
