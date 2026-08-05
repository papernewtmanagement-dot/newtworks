-- Aggressive length trim leg 1 of 2, Peter directive 2026-08-05 ("accurate read first;
-- go aggressive if research supports it").
--
-- RETESTS 25 -> 8. One verbatim repeat per trait far exceeds standard practice: careless-
-- response methodology uses a small handful of repeat pairs per instrument (Meade & Craig
-- 2012, Psych Methods 17:437-455; Curran 2016, JESP 66:4-19), and this battery also runs
-- even-odd consistency, straightlining, bogus-item, and response-time detectors that need
-- no repeats at all. hiregauge_v2_careless_retest_divergence counts pairs dynamically
-- (n_pairs guard) — robust to 8. Facet scoring anchors retest answers to their original
-- (COALESCE(retest_of_item_number, item_number)) and averages, so removing a repeat drops
-- a second reading of one item, not an item — near-zero accuracy cost.
-- KEPT 8, spread across trait families, both keyings, early-to-late positions:
-- 224 sincerity (stint 1, rev) | 229 self_efficacy | 234 anxiety | 236 trust
-- 238 friendliness->51 (documented dual-trait design) | 241 self_discipline
-- 242 cautiousness (rev) | 397 competitiveness.
-- Every kept anchor (11, 63, 123, 143, 51, 193, 203, 389) survives the trait trims.
UPDATE hiregauge_instrument_items SET is_active = false
WHERE section='newtworks_v2_personality'
  AND item_number IN (223,225,226,227,228,230,231,233,235,237,239,240,243,375,394,395,396);

-- SJT 20 -> 15 (4 -> 3 per topic). Within-topic scenarios are near-clones following one
-- rule in different costumes; clustered near-clone questions carry far less independent
-- information than their count suggests (testlet local dependence: Wainer & Kiely 1987,
-- JEM 24:185-201; Sireci, Thissen & Wainer 1991, JEM 28:237-247). Survivors chosen as the
-- three most-different scenarios per topic. SJT composite validity rests on the total
-- score (McDaniel, Hartman, Whetzel & Grubb 2007, Personnel Psych 60:63-91); 15 items
-- remains within the normal commercial SJT range. Per-topic consumers verified robust:
-- _newtworks_integrity_decline_gate reads n dynamically (50% floor still trips on 0/3,
-- 1/3); hiregauge_v2_normalized_inputs iterates topic keys generically.
-- Cuts: 11 licensing (bind-now = quote rule + urgency dressing; urgency covered in
-- composure) | 16 consent (verbal-undocumented duplicates undocumented-list #3) |
-- 30 composure (generic multi-failure, duplicates #32) | 13 escalation (beyond-authority-
-- today, duplicates #6) | 23 honesty (report rounding, duplicates own-mistake #21).
UPDATE hiregauge_instrument_items SET is_active = false
WHERE section='newtworks_v2_sjt' AND item_number IN (11,16,30,13,23);
