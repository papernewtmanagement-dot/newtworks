-- Aggressive length trim leg 2 of 2, Peter directive 2026-08-05.
--
-- BASELINE TRAIT TRIMS: unconditional stint-2 load drops from 6 (or 5/10) baseline items
-- per trait to 4 (customer_orientation and proactive_personality to 6). Research basis:
-- IPIP-NEO-120 cut 8->4 items per trait with criterion validity retained (Johnson 2014,
-- J Research in Personality 51:78-89); 4 is the floor below which validity attenuates
-- meaningfully (Crede, Harms, Niehorster & Gaye-Valentine 2012, JPSP 102:874-888).
-- Survivor selection is content-based (breadth preserved per Smith, McCarthy & Anderson
-- 2000, Psych Assessment 12:102-111): near-duplicate wordings cut first, keying balance
-- kept, all retained-retest anchors kept. Countervailing gain: careless responding rises
-- with test length (Bowling et al. 2021), so shorter = cleaner data.
--
-- CUT ITEMS MOVE TO THE STINT-3 ADAPTIVE POOL, NOT DEACTIVATION: candidates whose merged
-- stint-1+2 trait score lands in the 45-55 ambiguous band still receive up to 4 of these
-- exact items adaptively (compute_newtworks_v2_stint3_triggers discovers pool facets
-- dynamically — verified). Converts always-served into served-when-uncertain, the highest
-- accuracy-per-item spend in the instrument. Trigger band deliberately NOT narrowed.
--
-- PROTECTED AT 6 BASELINE (complete fixed published scales, no research cover for cutting
-- below the published form): dispositional_optimism (LOT-R, Scheier Carver & Bridges
-- 1994), political_skill_networking (PSI subscale, Ferris et al. 2005), self_efficacy
-- (GSE-6, Romppel et al. 2013). avoid/prove goal orientation already at 4 (VandeWalle
-- 1997 subscale floors).
UPDATE hiregauge_instrument_items SET stint = 3
WHERE section='newtworks_v2_personality' AND is_active AND stint = 2
  AND item_number IN (
    179,182,        -- achievement_striving: cut goal/plunge near-dupes; keep 180,181,183,184
    130,131,        -- anger: cut irritated/upset clones of 129; keep 129,132,133,134(rev)
    120,121,        -- anxiety: cut fear-worst/afraid clones; keep 119,122,123(anchor),124(rev)
    38,41,          -- assertiveness: cut want-charge + take-control dupes; keep 37,39,40,42
    201,204,        -- cautiousness: 201 is persistence content, 204 dupes 202/203; keep 199,200,202,203(anchor)
    48,52,          -- compassion: 48 is gregariousness content, 52 dupes 47/51; keep 47,49,50,51(anchor,dual-scored)
    149,154,        -- cooperation: 149 vague, 154 dupes 152; keep 150,151,152,153 (2 fwd/2 rev)
    112,113,        -- enterprising: lawsuit/salon least domain-relevant; keep 109,110,111,114
    189,192,        -- self_discipline: right-away/at-once clones of 191; keep 190,191,193(anchor),194(rev)
    142,144,        -- trust: 142 dupes 143, 144 is optimism content; keep 139,140,141,143(anchor)
    172,            -- dutifulness: truth-telling covered by integrity section; keep 170,171,173,174(rev) +1 shared
    211,            -- emotional_stability: dupes 209; keep 209,210,212,213 +2 shared
    162,            -- friendliness: act-comfortably dupes 161; keep 159,160,161,164(rev) + 51 shared
    376,            -- learning_goal_orientation: dupes 378; keep 377,378,379,380
    393,            -- competitiveness: dupes 392; keep 389(anchor),390,391,392
    366,368,372,373,-- customer_orientation 10->6, 3 customer-first + 3 selling-pressure(rev): keep 365,367,369 / 370,371,374
    69,71,77,78     -- proactive 10->6: 77 near-verbatim of 73, 78 dupes 75, 69 dupes 76, 71 affective-weakest; keep 70,72,73,74,75,76
  );

-- INTEGRITY 6 -> 5 per trait (stint 1; integrity has no stint-3 pool by design, so these
-- deactivate). Integrity-test validity is robust at 5 items per facet (Ones, Viswesvaran
-- & Schmidt 1993, JAP 78:679-703 monograph).
-- Cuts: 14 sincerity (overlaps 13), 23 fairness (overlaps 25), 27 greed_avoidance
-- (celebrity-fame, most distant from workplace greed; status item 31 covers it).
UPDATE hiregauge_instrument_items SET is_active = false
WHERE section='newtworks_v2_personality' AND stint = 1 AND item_number IN (14, 23, 27);

-- CROSS-SCORING: shore the two highest-validity conscientiousness facets back to 5
-- effective scored items via shared-item scoring (established in-instrument mechanism,
-- migration 20260803000100; compute_newtworks_v2_facets_as_row reads extra traits).
-- Achievement predicts objective sales at .41, the strongest personality finding in the
-- literature (Vinchur, Schippmann, Switzer & Roth 1998, JAP 83:586-597); industriousness
-- content genuinely spans both facets (DeYoung, Quilty & Peterson 2007 aspect structure).
-- Guardrails honored: content genuinely fits both facets; shared items stay a minority of
-- each facet's scored set (1 of 5); heavy item-sharing avoided (Helmes & Reddon 1993,
-- Psych Bulletin 113:453-471).
INSERT INTO hiregauge_item_extra_traits (section, item_number, hypothesized_trait, reverse_coded, is_scored_facet, source_note)
VALUES
  ('newtworks_v2_personality', 193, 'achievement_striving', false, true,
   '2026-08-05 trim cross-score: "I carry out my plans" (self_discipline home) also scored for achievement_striving — plan follow-through is industriousness content spanning both facets. Keeps achievement at 5 effective items after 6->4 baseline trim.'),
  ('newtworks_v2_personality', 180, 'self_discipline', false, true,
   '2026-08-05 trim cross-score: "I work hard" (achievement_striving home) also scored for self_discipline — sustained effort is industriousness content spanning both facets. Keeps self_discipline at 5 effective items after 6->4 baseline trim.');
