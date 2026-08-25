-- WIPE THE OLD SYSTEM (Peter directive 2026-08-25: "get rid of all old scores. The old
-- system is wiped out"). Follows fc_quad_go_live_and_retire_pairs, which removed the pair
-- test; this removes everything else that belonged to the pre-quad personality system.
--
-- What goes:
--   1. Every switched-off question in the bank (269 rows: 17 stint-1 personality, 59
--      stint-2 reasoning, 166 stint-2 rating-scale personality, 2 stint-3, 25 scenario).
--      Their candidate answers go with them (FK cascade).
--   2. Section 3 -- the 95 rating-scale follow-up questions that fired on borderline
--      personality scores. They only understood the old format and could not fire under
--      the quad section (compute_newtworks_v2_stint3_triggers hardcoded the old section).
--      Items, answers (21 people) and the trigger function all removed. The edge function
--      drops its stint-3 stage in the companion commit.
--   3. Old-system personality scores: the 25 facet columns, assessment_source and
--      assessment_completed_at are cleared for every candidate whose source was the
--      rating-scale ('v2') or earlier ('v1', 'cts') system. GMA / SJT / screen results are
--      untouched -- those sections are unchanged and were never part of the old
--      personality system.
--
-- What stays, on purpose: Section 1 (honesty questions + reasoning + vocabulary check),
-- scenarios, the written screen, and compute_newtworks_v2_facets_as_row, which the
-- Section 1 honesty exit gate (hiregauge_v2_stint1_exit_gate) still calls.

-- 1 + 2: questions ---------------------------------------------------------------------
DELETE FROM public.hiregauge_instrument_items
WHERE is_active = false OR stint = 3;

DROP FUNCTION IF EXISTS public.compute_newtworks_v2_stint3_triggers(uuid);

-- 3: scores ----------------------------------------------------------------------------
UPDATE public.hiring_candidates
SET achievement_striving = NULL, competitiveness = NULL, learning_goal_orientation = NULL,
    prove_goal_orientation = NULL, avoid_goal_orientation = NULL, self_discipline = NULL,
    emotional_stability = NULL, assertiveness = NULL, dutifulness = NULL,
    customer_orientation = NULL, self_efficacy = NULL, proactive_personality = NULL,
    cautiousness = NULL, anxiety = NULL, friendliness = NULL, anger = NULL,
    cooperation = NULL, trust = NULL, compassion = NULL, dispositional_optimism = NULL,
    political_skill_networking = NULL, enterprising = NULL, sincerity = NULL,
    fairness = NULL, greed_avoidance = NULL,
    assessment_source = NULL,
    assessment_completed_at = NULL
WHERE assessment_source IN ('v2', 'v1', 'cts');
