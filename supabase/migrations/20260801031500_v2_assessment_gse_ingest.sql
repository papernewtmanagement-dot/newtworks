-- v2 assessment: General Self-Efficacy Scale (GSE) 10-item ingest into newtworks_v2_personality
-- Source: Schwarzer, R., & Jerusalem, M. (1995). Generalized Self-Efficacy scale.
--   In J. Weinman, S. Wright, & M. Johnston, Measures in health psychology: A user's portfolio.
--   Causal and control beliefs (pp. 35-37). Windsor, UK: NFER-NELSON.
-- English version verbatim from userpage.fu-berlin.de/~health/engscal.htm (Schwarzer's canonical page).
-- Unidimensional. All 10 items +keyed (no reverse coding per source). 4-point scale (1=Not at all true, 4=Exactly true).
-- Scoring: unit-weighted composite (sum, range 10-40 per source). Cronbach's α .76-.90 across 23 nations.
-- v2 item numbers 59-68, Stint 2 (personality baseline).
-- Note: scale_max=4 introduces mixed scale within newtworks_v2_personality section (LOT-R/HEXACO/IPIP all scale_max=5).
--   Preserving source integrity per op-rule "Hardcoded functions: never prefer simpler over more accurate".
--   Frontend serving code must read scale_max per item, not assume section-wide.

INSERT INTO public.hiregauge_instrument_items (
  section, item_number, hypothesized_trait, item_text, reverse_coded, scale_max, stint, choices, notes
) VALUES
('newtworks_v2_personality', 59, 'self_efficacy', 'I can always manage to solve difficult problems if I try hard enough.',                  false, 4, 2, NULL, 'GSE canonical item 1. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.'),
('newtworks_v2_personality', 60, 'self_efficacy', 'If someone opposes me, I can find the means and ways to get what I want.',              false, 4, 2, NULL, 'GSE canonical item 2. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.'),
('newtworks_v2_personality', 61, 'self_efficacy', 'It is easy for me to stick to my aims and accomplish my goals.',                        false, 4, 2, NULL, 'GSE canonical item 3. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.'),
('newtworks_v2_personality', 62, 'self_efficacy', 'I am confident that I could deal efficiently with unexpected events.',                  false, 4, 2, NULL, 'GSE canonical item 4. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.'),
('newtworks_v2_personality', 63, 'self_efficacy', 'Thanks to my resourcefulness, I know how to handle unforeseen situations.',            false, 4, 2, NULL, 'GSE canonical item 5. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.'),
('newtworks_v2_personality', 64, 'self_efficacy', 'I can solve most problems if I invest the necessary effort.',                          false, 4, 2, NULL, 'GSE canonical item 6. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.'),
('newtworks_v2_personality', 65, 'self_efficacy', 'I can remain calm when facing difficulties because I can rely on my coping abilities.', false, 4, 2, NULL, 'GSE canonical item 7. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.'),
('newtworks_v2_personality', 66, 'self_efficacy', 'When I am confronted with a problem, I can usually find several solutions.',            false, 4, 2, NULL, 'GSE canonical item 8. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.'),
('newtworks_v2_personality', 67, 'self_efficacy', 'If I am in trouble, I can usually think of a solution.',                                false, 4, 2, NULL, 'GSE canonical item 9. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.'),
('newtworks_v2_personality', 68, 'self_efficacy', 'I can usually handle whatever comes my way.',                                          false, 4, 2, NULL, 'GSE canonical item 10. Schwarzer & Jerusalem 1995, English at userpage.fu-berlin.de/~health/engscal.htm. 4-point scale, +keyed.');
