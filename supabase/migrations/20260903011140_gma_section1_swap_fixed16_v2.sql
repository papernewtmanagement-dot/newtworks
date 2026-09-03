-- Step 2 of 2: make the harder Section 1 GMA set live.
--
-- Retires items 1, 3 (shape) and 61, 67 (word) -- p 0.95, 0.95, 0.95, 1.00 on
-- the first 19 completions -- and activates 76, 77 (shape) and 78, 79 (word).
-- The count stays at 16 (Peter ruling 2026-09-02: swap, do not expand; revisit
-- only if spread is still short). The numerical trio at p = .84 (31, 34, 42)
-- is the next swap candidate.
--
-- SAFE BECAUSE: the assessment endpoint (v51, deployed just before this) reads
-- the GMA half of Section 1 from the candidate's own item set, not is_active.
-- The 69 candidates already locked to fixed16_v1 keep being served the old 16,
-- keep being able to save answers to them, and keep being scored against the
-- old norm, which is frozen into 'gma@fixed16_v1' / 'gma_speed@fixed16_v1'
-- below. Only someone who has not yet answered a single GMA item gets the new
-- set.
--
-- NORM SEEDS FOR THE NEW SET. A local norm describes one item set and cannot
-- be carried across a content change (Nunnally & Bernstein 1994; AERA/APA/NCME
-- Standards 2014). Seeds are computed from live data on the 12 surviving
-- items, not invented:
--   accuracy mean = (12 x 66.23% + 4 x 55%) / 16 = 63.4%
--     -- 66.23% is the observed mean on the 12 kept items across the same 19
--        completions; 55% is the target difficulty of the four new items
--        (2 stacked conceptual rules for the shape items; a non-obvious
--        relation with associated-but-wrong distractors for the word items),
--        sitting between the observed .79 and .32 anchors on this bank.
--   accuracy SD = 21.0 points. Observed SD on the kept 12 is 21.96 points
--     (2.63 items). Four items near p = .55 add roughly 1.0 item^2 of
--     variance, which by itself implies about 17.6 points on 16 items; real
--     items correlate with the total and add more, so 21.0 is the deliberate
--     middle. ERRING HIGH ON PURPOSE: a norm SD that is too small pushes
--     every percentile toward the extremes, and the extreme that costs a real
--     person something is the low one.
--   speed mean 1.62 / SD 0.75 correct items per minute -- observed on the
--     kept 12 among the 16 candidates above the reasoning floor (the full-16
--     figure, 2.01, is inflated by the four easy items being answered almost
--     instantly).
-- Both rows are PROVISIONAL and carry norm_status 'provisional_seed';
-- hiregauge_gma_norm_rebuild_current_set replaces them automatically from real
-- completions at N >= 20 and rescores everyone on the set.
--
-- The reasoning floor for the new set is DERIVED, not inherited: chance + 2 SD
-- from the real option counts is 7 of 16 (43.75%), and gate C stays at <= 3
-- correct. The old set keeps the ruled 62.5% by override, so no existing
-- decline changes.

-- Anyone who answered a GMA item during the deploy window answered the old set.
UPDATE public.hiring_candidates c
SET gma_item_set = 'fixed16_v1'
WHERE c.gma_item_set IS NULL
  AND EXISTS (
    SELECT 1 FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = c.id AND i.section = 'newtworks_v2_cognitive_gma'
  );

-- Freeze the retiring set's norm under its own keys BEFORE it stops being
-- current, so the 69 candidates on it never read a seed meant for the new set.
INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_by, updated_at)
SELECT agency_id, facet || '@fixed16_v1', ref_mean_0_100, ref_sd_0_100, source_scale, citation,
       retrieved_from,
       'FROZEN 2026-09-02 when item set fixed16_v1 was retired. Values copied verbatim from the then-current ' || facet || ' row (rebuilt 2026-09-02 from 19 completions). Candidates locked to fixed16_v1 score against this row forever; do not edit, and do not pool with any later set.',
       'claude_migration_gma_section1_swap', now()
FROM public.hiregauge_facet_norms
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND facet IN ('gma','gma_speed')
ON CONFLICT (agency_id, facet) DO NOTHING;

-- Flip which set is current (unset first -- one current set per agency).
UPDATE public.hiregauge_gma_item_sets
SET is_current = false, retired_at = now(), norm_status = 'frozen', updated_at = now()
WHERE set_key = 'fixed16_v1';

UPDATE public.hiregauge_gma_item_sets
SET is_current = true, activated_at = now(), updated_at = now()
WHERE set_key = 'fixed16_v2';

-- Reseed the live norm rows for the new set.
UPDATE public.hiregauge_facet_norms
SET ref_mean_0_100 = 63.40,
    ref_sd_0_100   = 21.00,
    source_scale   = 'newtworks_v2 cognitive section, percent-correct over the 16 fixed Section 1 items of set fixed16_v2 (4 pattern, 4 numerical, 4 deductive, 4 verbal)',
    retrieved_from = 'PROVISIONAL SEED 2026-09-02 for item set fixed16_v2: 12 surviving items measured on 19 completions (mean 66.23%, SD 21.96 points) plus 4 new items at a target difficulty of 55% correct',
    notes          = 'PROVISIONAL SEED, not a measured norm. Item set fixed16_v2. Rebuilt automatically at N>=20 completions on this set by hiregauge_gma_norm_rebuild_current_set (trigger trg_gma_norm_auto_rebuild), then refresh at N>=50 with p_force. SD deliberately erring high: too small an SD pushes percentiles to the extremes and the low extreme costs a real person a decline. The retired set fixed16_v1 keeps its own measured norm at gma@fixed16_v1 -- never pool the two.',
    updated_by     = 'claude_migration_gma_section1_swap',
    updated_at     = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND facet = 'gma';

UPDATE public.hiregauge_facet_norms
SET ref_mean_0_100 = 1.6200,
    ref_sd_0_100   = 0.7500,
    retrieved_from = 'PROVISIONAL SEED 2026-09-02 for item set fixed16_v2: correct items per minute on the 12 surviving items, among the 16 of 19 completions at or above the reasoning floor (mean 1.6150, SD 0.7534)',
    notes          = 'PROVISIONAL SEED, not a measured norm. Item set fixed16_v2. Higher correct-items-per-minute = better (natural direction, no inversion). Correct-items-only per Peter directive; wrong answers contribute nothing either way. Rebuilt at N>=20 on this set (only if at least 10 usable timings). The retired set keeps gma_speed@fixed16_v1.',
    updated_by     = 'claude_migration_gma_section1_swap',
    updated_at     = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND facet = 'gma_speed';

-- Retire the four near-ceiling items, activate the four replacements.
UPDATE public.hiregauge_instrument_items
SET is_active = false, updated_at = now()
WHERE section = 'newtworks_v2_cognitive_gma' AND item_number IN (1,3,61,67);

UPDATE public.hiregauge_instrument_items
SET is_active = true, updated_at = now()
WHERE section = 'newtworks_v2_cognitive_gma' AND item_number IN (76,77,78,79);
