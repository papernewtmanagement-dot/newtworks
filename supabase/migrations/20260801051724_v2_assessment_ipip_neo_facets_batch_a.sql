-- v2 assessment: IPIP-NEO facet ingest batch A — Anxiety, Anger, Trust, Cooperation
-- Source: Goldberg, L.R. et al. IPIP representation of NEO PI-R facets. ipip.ori.org/newNEOKey.htm.
-- Public domain. Item text + keying direction taken verbatim from IPIP's own published scoring key
-- (source explicitly labels each item +keyed or -keyed; reverse_coded set accordingly).
-- All 10 items per facet, scale_max=5, Stint 2.

INSERT INTO public.hiregauge_instrument_items (
  section, item_number, hypothesized_trait, item_text, reverse_coded, scale_max, stint, choices, notes
) VALUES
-- ANXIETY (N1, alpha=.83) — items 119-128
('newtworks_v2_personality', 119, 'anxiety', 'Worry about things.',                                  false, 5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 1/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 120, 'anxiety', 'Fear for the worst.',                                   false, 5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 2/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 121, 'anxiety', 'Am afraid of many things.',                             false, 5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 3/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 122, 'anxiety', 'Get stressed out easily.',                              false, 5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 4/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 123, 'anxiety', 'Get caught up in my problems.',                         false, 5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 5/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 124, 'anxiety', 'Am not easily bothered by things.',                     true,  5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 6/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 125, 'anxiety', 'Am relaxed most of the time.',                          true,  5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 7/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 126, 'anxiety', 'Am not easily disturbed by events.',                    true,  5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 8/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 127, 'anxiety', 'Don''t worry about things that have already happened.', true,  5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 9/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 128, 'anxiety', 'Adapt easily to new situations.',                       true,  5, 2, NULL, 'IPIP-NEO facet N1 Anxiety, item 10/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
-- ANGER (N2, alpha=.88) — items 129-138
('newtworks_v2_personality', 129, 'anger', 'Get angry easily.',                                       false, 5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 1/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 130, 'anger', 'Get irritated easily.',                                   false, 5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 2/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 131, 'anger', 'Get upset easily.',                                       false, 5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 3/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 132, 'anger', 'Am often in a bad mood.',                                 false, 5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 4/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 133, 'anger', 'Lose my temper.',                                         false, 5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 5/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 134, 'anger', 'Rarely get irritated.',                                   true,  5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 6/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 135, 'anger', 'Seldom get mad.',                                         true,  5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 7/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 136, 'anger', 'Am not easily annoyed.',                                  true,  5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 8/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 137, 'anger', 'Keep my cool.',                                           true,  5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 9/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 138, 'anger', 'Rarely complain.',                                        true,  5, 2, NULL, 'IPIP-NEO facet N2 Anger, item 10/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
-- TRUST (A1, alpha=.82) — items 139-148
('newtworks_v2_personality', 139, 'trust', 'Trust others.',                                           false, 5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 1/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 140, 'trust', 'Believe that others have good intentions.',                false, 5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 2/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 141, 'trust', 'Trust what people say.',                                  false, 5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 3/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 142, 'trust', 'Believe that people are basically moral.',                false, 5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 4/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 143, 'trust', 'Believe in human goodness.',                              false, 5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 5/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 144, 'trust', 'Think that all will be well.',                            false, 5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 6/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 145, 'trust', 'Distrust people.',                                        true,  5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 7/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 146, 'trust', 'Suspect hidden motives in others.',                       true,  5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 8/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 147, 'trust', 'Am wary of others.',                                      true,  5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 9/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 148, 'trust', 'Believe that people are essentially evil.',                true,  5, 2, NULL, 'IPIP-NEO facet A1 Trust, item 10/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
-- COOPERATION (A4, alpha=.73) — items 149-158
('newtworks_v2_personality', 149, 'cooperation', 'Am easy to satisfy.',                                false, 5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 1/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 150, 'cooperation', 'Can''t stand confrontations.',                        false, 5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 2/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 151, 'cooperation', 'Hate to seem pushy.',                                false, 5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 3/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked +keyed.'),
('newtworks_v2_personality', 152, 'cooperation', 'Have a sharp tongue.',                               true,  5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 4/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 153, 'cooperation', 'Contradict others.',                                 true,  5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 5/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 154, 'cooperation', 'Love a good fight.',                                 true,  5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 6/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 155, 'cooperation', 'Yell at people.',                                    true,  5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 7/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 156, 'cooperation', 'Insult people.',                                     true,  5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 8/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 157, 'cooperation', 'Get back at others.',                                true,  5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 9/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.'),
('newtworks_v2_personality', 158, 'cooperation', 'Hold a grudge.',                                     true,  5, 2, NULL, 'IPIP-NEO facet A4 Cooperation, item 10/10. ipip.ori.org/newNEOKey.htm, public domain. Source-marked -keyed.');
