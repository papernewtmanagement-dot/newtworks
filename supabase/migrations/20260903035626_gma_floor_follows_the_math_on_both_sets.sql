-- CORRECTION 2026-09-02. Removes the floor_pct_override (62.5) and
-- gate_c_max_correct_override (3) from item set fixed16_v1, so BOTH sets
-- derive their reasoning floor from the actual option counts.
--
-- WHY THE OVERRIDE EXISTED AND WHY IT SHOULD NOT: it was written into
-- migration gma_item_sets_seed_and_new_items on the stated basis that Peter
-- had ruled the 62.5% floor stands. He had not. The standing instruction is
-- and has been to follow what the peer-reviewed research supports. This
-- migration removes an assumption that was never a decision.
--
-- WHAT THE RESEARCH SUPPORTS. The gate's own design record (migration
-- reasoning_gate_chance_anchored_provisional, 2026-08-05) states its purpose:
-- fire only when a score cannot be distinguished from guessing. On these 16
-- items -- twelve with six options, four with three -- a pure guesser's
-- expected score is 3.33 correct with an SD of 1.60, so chance + 2 SD is 7 of
-- 16 (43.75%). The exact Poisson-binomial probability that a pure guesser
-- reaches 7 is 3.05%, inside the conventional 5% band (Lord & Novick 1968,
-- Statistical Theories of Mental Test Scores, ch. 14). The original 62.5%
-- came from a derivation that assumed two-option items and is about 1.8x the
-- correct value.
--
-- A cutoff set above the chance band is no longer a chance floor -- it is an
-- ability cutoff, and professional standards require local validation
-- evidence before one is used to screen people out (AERA/APA/NCME Standards
-- for Educational and Psychological Testing 2014, ch. 11; Cascio, Alexander
-- & Barrett 1988, Personnel Psychology 41:1-24 on cutoff-score methods).
-- There is no such evidence here: 19 completions and no job-outcome data.
-- Cognitive measures also produce the largest subgroup mean differences of
-- any common selection tool (Roth, Bevier, Bobko, Switzer & Tyler 2001,
-- Personnel Psychology 54:297-330; Ployhart & Holtz 2008, Personnel
-- Psychology 61:153-172), which makes an unvalidated high cutoff the single
-- least defensible thing in a hiring process. Ranking is what the composite
-- score is for; the floor's only job is to catch scores indistinguishable
-- from random clicking.
--
-- EFFECT ON EXISTING CANDIDATES: one. Gate C (the stint-1 hard eliminator) is
-- unchanged -- the derived value is floor(3.33) = 3, identical to the
-- override. The reasoning floor moves from 10 correct to 7, so of the 19
-- scored candidates only Jennifer A. (7 of 16) changes: the floor stops
-- firing for her and her verdict is no longer capped. Julia H. (5) and
-- Natalie M. (6) remain below the derived floor and are unaffected. Nobody
-- above 7 was ever touched by this gate.
UPDATE public.hiregauge_gma_item_sets
SET floor_pct_override = NULL,
    gate_c_max_correct_override = NULL,
    notes = 'Fixed 16 items, live 2026-08-25 to 2026-09-02. Retired when four near-ceiling items (1, 3, 61, 67 at p .95-1.00) were swapped out. Reasoning floor is DERIVED like every other set: chance + 2 SD from the real option counts = 7 of 16 (43.75%), gate C at <= 3 correct. The 62.5% floor this set ran on until 2026-09-02 came from a derivation that assumed 2-option items and was about 1.8x too strict; it was removed rather than pinned, because no validation evidence supports an ability cutoff above the chance band. Norm frozen at gma@fixed16_v1 (74.11/17.84, N=19) and gma_speed@fixed16_v1 (2.0094/0.9345, N=16).',
    updated_at = now()
WHERE set_key = 'fixed16_v1';
