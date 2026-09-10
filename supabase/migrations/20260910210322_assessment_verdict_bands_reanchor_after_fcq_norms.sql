-- Re-anchor the assessment verdict bands after the fcq norm rebuild (2026-09-10).
--
-- The 2026-09-04 bands (consider 60 / pass 70) were set judgmental-normatively
-- (Cascio, Alexander & Barrett 1988) against the pool as scored on the
-- provisional 50/13 personality seed: mean 65.18, SD 3.97, decline at about
-- -1.3 SD, pass at about +1.2 SD. Migration fcq_facet_norms_rebuild_n26
-- replaced that seed with the observed pool norms, which moved every composite
-- down 9-18 points: the pool now sits at mean 51.08, SD 5.61 (N=27). Under the
-- old bands 24 of 26 read "decline" and any new completion would be
-- auto-declined by hiring-interview-scheduler (composite < consider_threshold).
--
-- Same rule, new numbers: decline below 51.08 - 1.3*5.61 = 43.8 -> 44;
-- pass at 51.08 + 1.2*5.61 = 57.8 -> 58. Consider 44-57. Still PROVISIONAL and
-- advisory; recalibrate against on-job outcomes, and revisit after
-- construct-level weighting lands (open_question 54da3000).

UPDATE public.hiregauge_verdict_thresholds
SET consider_threshold = 44,
    pass_threshold = 58,
    notes = 'Assessment layer — percentile-metric composite. 58+ pass, 44-57 consider, <44 decline. RE-ANCHORED 2026-09-10 after the fcq personality norms were rebuilt from the live pool (migration fcq_facet_norms_rebuild_n26): the pool moved from mean 65.18 / SD 3.97 to mean 51.08 / SD 5.61 (N=27), so the 2026-09-04 bands (60/70) sat 1.6 and 3.4 SD above the new mean and would have auto-declined nearly everyone. Same judgmental-normative rule as 2026-09-04 (Cascio, Alexander & Barrett 1988): decline ~ -1.3 SD, pass ~ +1.2 SD, cutoffs clear ~2 SEM (AERA/APA/NCME Standards 2014 ch. 2, 5), permissive screen because ranking carries the utility (Taylor & Russell 1939). PROVISIONAL — advisory only, final call is a documented human decision (Schmidt, Mack & Hunter 1984). Recalibrate at N>=50 or against on-job outcomes, never against pre-outcome candidate scores. The compression defect (25 personality inputs vs 1 cognitive) is unchanged; construct-level weighting is the real fix (open_question 54da3000) — revisit these bands after it lands.',
    updated_at = now()
WHERE layer = 'assessment';
