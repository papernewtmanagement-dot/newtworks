-- v2 assessment: Emotional Stability + Assured-Dominance ingest into newtworks_v2_personality
-- EMOTIONAL STABILITY: not a standalone IPIP-NEO facet. Sourced from the 10-item NEUROTICISM
--   domain scale (alpha=.86) at ipip.ori.org/newNEOKey.htm, public domain. Item content unchanged;
--   reverse_coded flags FLIPPED relative to source because Emotional Stability is the logical
--   opposite of Neuroticism (Path A: key items to match the trait actually being measured/labeled,
--   not the source scale's original direction). Source +keyed items (agree = high neuroticism) are
--   reverse_coded=true here (agree = LOW emotional stability). Source -keyed items (agree = low
--   neuroticism) are reverse_coded=false here (agree = HIGH emotional stability).
-- ASSURED-DOMINANCE: not an IPIP-NEO facet either. Sourced from the IPIP Interpersonal Circumplex
--   (IPIP-IPC), Markey, P.M. & Markey, C.N. (2009). Assessment, 16, 352-361. Public domain,
--   ipip.ori.org/newIPIP-IPCScoringKey.htm. PA (Assured-Dominant) octant = 4 items, all +keyed
--   per source (all IPIP-IPC items are +keyed by design). Item count corrected from any prior
--   handoff assumption of 10 — verified against primary source per session 3 lesson.
-- scale_max=5, Stint 2.

INSERT INTO public.hiregauge_instrument_items (
  section, item_number, hypothesized_trait, item_text, reverse_coded, scale_max, stint, choices, notes
) VALUES
-- EMOTIONAL STABILITY (reverse of NEUROTICISM 10-item domain scale) — items 209-218
('newtworks_v2_personality', 209, 'emotional_stability', 'Often feel blue.',                            true,  5, 2, NULL, 'Emotional Stability item 1/10, sourced from IPIP NEUROTICISM domain scale item 1 (source +keyed for neuroticism; flipped to reverse_coded for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
('newtworks_v2_personality', 210, 'emotional_stability', 'Dislike myself.',                             true,  5, 2, NULL, 'Emotional Stability item 2/10, sourced from IPIP NEUROTICISM domain scale item 2 (source +keyed for neuroticism; flipped to reverse_coded for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
('newtworks_v2_personality', 211, 'emotional_stability', 'Am often down in the dumps.',                  true,  5, 2, NULL, 'Emotional Stability item 3/10, sourced from IPIP NEUROTICISM domain scale item 3 (source +keyed for neuroticism; flipped to reverse_coded for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
('newtworks_v2_personality', 212, 'emotional_stability', 'Have frequent mood swings.',                  true,  5, 2, NULL, 'Emotional Stability item 4/10, sourced from IPIP NEUROTICISM domain scale item 4 (source +keyed for neuroticism; flipped to reverse_coded for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
('newtworks_v2_personality', 213, 'emotional_stability', 'Panic easily.',                               true,  5, 2, NULL, 'Emotional Stability item 5/10, sourced from IPIP NEUROTICISM domain scale item 5 (source +keyed for neuroticism; flipped to reverse_coded for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
('newtworks_v2_personality', 214, 'emotional_stability', 'Rarely get irritated.',                       false, 5, 2, NULL, 'Emotional Stability item 6/10, sourced from IPIP NEUROTICISM domain scale item 6 (source -keyed for neuroticism; flipped to +keyed for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
('newtworks_v2_personality', 215, 'emotional_stability', 'Seldom feel blue.',                           false, 5, 2, NULL, 'Emotional Stability item 7/10, sourced from IPIP NEUROTICISM domain scale item 7 (source -keyed for neuroticism; flipped to +keyed for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
('newtworks_v2_personality', 216, 'emotional_stability', 'Feel comfortable with myself.',               false, 5, 2, NULL, 'Emotional Stability item 8/10, sourced from IPIP NEUROTICISM domain scale item 8 (source -keyed for neuroticism; flipped to +keyed for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
('newtworks_v2_personality', 217, 'emotional_stability', 'Am not easily bothered by things.',           false, 5, 2, NULL, 'Emotional Stability item 9/10, sourced from IPIP NEUROTICISM domain scale item 9 (source -keyed for neuroticism; flipped to +keyed for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
('newtworks_v2_personality', 218, 'emotional_stability', 'Am very pleased with myself.',                false, 5, 2, NULL, 'Emotional Stability item 10/10, sourced from IPIP NEUROTICISM domain scale item 10 (source -keyed for neuroticism; flipped to +keyed for Emotional Stability). ipip.ori.org/newNEOKey.htm, public domain.'),
-- ASSURED-DOMINANCE (IPIP-IPC PA octant, Markey & Markey 2009) — items 219-222
('newtworks_v2_personality', 219, 'assured_dominance', 'Demand to be the center of interest.',          false, 5, 2, NULL, 'Assured-Dominance item 1/4. IPIP-IPC PA octant, Markey & Markey 2009, Assessment 16:352-361. ipip.ori.org/newIPIP-IPCScoringKey.htm, public domain. All IPIP-IPC items +keyed.'),
('newtworks_v2_personality', 220, 'assured_dominance', 'Do most of the talking.',                       false, 5, 2, NULL, 'Assured-Dominance item 2/4. IPIP-IPC PA octant, Markey & Markey 2009, Assessment 16:352-361. ipip.ori.org/newIPIP-IPCScoringKey.htm, public domain. All IPIP-IPC items +keyed.'),
('newtworks_v2_personality', 221, 'assured_dominance', 'Speak loudly.',                                 false, 5, 2, NULL, 'Assured-Dominance item 3/4. IPIP-IPC PA octant, Markey & Markey 2009, Assessment 16:352-361. ipip.ori.org/newIPIP-IPCScoringKey.htm, public domain. All IPIP-IPC items +keyed.'),
('newtworks_v2_personality', 222, 'assured_dominance', 'Demand attention.',                             false, 5, 2, NULL, 'Assured-Dominance item 4/4. IPIP-IPC PA octant, Markey & Markey 2009, Assessment 16:352-361. ipip.ori.org/newIPIP-IPCScoringKey.htm, public domain. All IPIP-IPC items +keyed.');
