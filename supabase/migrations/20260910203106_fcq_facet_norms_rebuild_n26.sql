-- fcq_<facet> norm rebuild from the live applicant pool (2026-09-10).
--
-- WHY: the 25 fcq_<facet> rows in hiregauge_facet_norms were the 2026-08-25
-- PROVISIONAL seed (mean 50 / SD 13), to be replaced with the observed pool
-- mean/SD at N >= 20 completed v2fcq sittings (design record: migration
-- fc_quad_scoring_phase1_norms_and_source; open_question d492190a). The pool
-- passed 20 on 2026-09-05 and stood at 27 when this ran. The seed was wrong
-- by more than a full SD on several facets (avoid_goal_orientation pool mean
-- 74.6 vs seed 50; customer_orientation 71.3; assertiveness 43.0; fairness
-- 43.1), so every candidate's percentiles and composite were distorted.
--
-- HOW: mean and sample SD of compute_newtworks_v2fcq_facets_as_row(id, 1)
-- over completed, non-test candidates whose personality source is v2fcq,
-- EXCLUDING sittings with reliability = 'low' (one candidate: ranking blocks
-- answered at a 2.7 s median with 58% pole consistency, i.e. noise). N = 26.
-- Same local-norm pattern as the gma/sjt rows (migration 20260814043100) and
-- the gma@<set> rows. Norm-referenced interpretation requires a norm built on
-- the same instrument and population (Nunnally & Bernstein 1994; AERA/APA/NCME
-- Standards 2014). Values are written as literals so the mirror reproduces
-- production state on a fresh clone.
--
-- PROVISIONAL: N = 26. Rebuild at N >= 50 on the same 75 blocks; any change to
-- the block set requires a fresh norm (never pool across item sets).
--
-- CACHE: the AFTER UPDATE trigger on hiregauge_facet_norms bumps
-- hiregauge_scoring_version; hiregauge_refresh_scoring_cache('all') is called
-- at the end so cached composites reflect the new norms immediately.

WITH v(facet, m, s) AS (VALUES
  ('fcq_achievement_striving',      58.38, 10.12),
  ('fcq_anger',                     48.73, 11.62),
  ('fcq_anxiety',                   57.08, 12.99),
  ('fcq_assertiveness',             43.00, 11.65),
  ('fcq_avoid_goal_orientation',    74.62,  9.86),
  ('fcq_cautiousness',              69.58, 12.13),
  ('fcq_compassion',                70.00, 11.59),
  ('fcq_competitiveness',           46.38, 17.52),
  ('fcq_cooperation',               53.42,  7.64),
  ('fcq_customer_orientation',      71.31, 12.22),
  ('fcq_dispositional_optimism',    58.35, 11.20),
  ('fcq_dutifulness',               68.08, 10.97),
  ('fcq_emotional_stability',       57.50, 10.66),
  ('fcq_enterprising',              54.54, 13.83),
  ('fcq_fairness',                  43.12,  8.74),
  ('fcq_friendliness',              64.92, 14.60),
  ('fcq_greed_avoidance',           67.42, 19.96),
  ('fcq_learning_goal_orientation', 65.81, 13.63),
  ('fcq_political_skill_networking',67.50, 10.87),
  ('fcq_proactive_personality',     51.54, 13.17),
  ('fcq_prove_goal_orientation',    49.50, 11.71),
  ('fcq_self_discipline',           54.27, 10.15),
  ('fcq_self_efficacy',             60.31, 11.09),
  ('fcq_sincerity',                 59.92,  8.76),
  ('fcq_trust',                     48.62, 10.06)
)
UPDATE public.hiregauge_facet_norms n
SET ref_mean_0_100 = v.m,
    ref_sd_0_100   = v.s,
    retrieved_from = 'LOCAL POOL NORM 2026-09-10: mean/sample SD of compute_newtworks_v2fcq_facets_as_row(id,1) over 26 completed non-test v2fcq sittings (27 completions minus 1 reliability=low sitting). Replaces the 2026-08-25 provisional 50/13 seed.',
    notes = 'PROVISIONAL local norm at N=26 (rebuild at N>=50 on the same 75 blocks; never pool across block sets). Excludes sittings with reliability=low. Seed history: 50/13 from 2026-08-25 to 2026-09-10. On these blocks the pool sits well off 50 on several facets (avoid_goal_orientation 74.6, customer_orientation 71.3, assertiveness 43.0, fairness 43.1), which is why the seed distorted percentiles; a facet whose pool mean lands 2 SD from the seed also deserves a wording check on its 12 statements.',
    updated_at = now(),
    updated_by = 'claude_migration_fcq_norms_rebuild_n26'
FROM v
WHERE n.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND n.facet = v.facet;

SELECT public.hiregauge_refresh_scoring_cache('126794dd-25ff-47d2-a436-724499733365', 'all');
