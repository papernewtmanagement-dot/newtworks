-- GMA norm rebuilt on the test candidates actually take now.
-- Peter ruling 2026-09-02: keep the compared-to-average scoring active; fix the average.
--
-- WHAT WAS WRONG: the 'gma' row (mean 80.68, SD 8.72) was computed 2026-08-14 from 31
-- completions of the July adaptive version (16 fixed items plus a 59-item adaptive
-- reasoning pool that served easier items to weaker candidates, which inflates
-- percent-correct at the low end). The adaptive pool was deleted 2026-08-25 with the old
-- bank. Since then every candidate answers the same fixed 16 items in Section 1, and the
-- first 19 completions on that test average 74.11% correct with SD 17.84. Against the
-- July row a 12-of-16 score (75%) read as the 26th percentile and 11-of-16 as the 13th,
-- which put four candidates under the role-fit floor gate (hiregauge_lss_penalty_v2 at
-- ideal_min 25-27) and drove auto-declines on differences the 16-item test cannot
-- resolve (KR-20 among the 16 candidates above the chance floor: -0.08).
--
-- WHAT THIS DOES: replaces mean/SD for 'gma' and 'gma_speed' with values computed from
-- the 19 v2fcq completions on the fixed 16-item test (all 19 answered exactly 16 items;
-- speed over the 16 candidates at or above the 62.5% reasoning floor, per the existing
-- correct-items-only definition). Numbers are written as literals, not recomputed on
-- apply, so a fresh database reproduces the same norm.
--
-- STILL PROVISIONAL. N = 19. Same rule as before: refresh at N >= 50 on the SAME item
-- set. The norm is tied to the item set: when the harder Section 1 items ship, this row
-- goes back to a provisional seed and is rebuilt once N >= 20 on the new set.
--
-- CACHE: this UPDATE fires trg_bump_scoring_version_norms, so cached role-fit composites
-- refresh on next read (see op-rule "HireGauge scoring cache architecture").

UPDATE public.hiregauge_facet_norms
SET ref_mean_0_100 = 74.11,
    ref_sd_0_100   = 17.84,
    source_scale   = 'newtworks_v2 cognitive section, percent-correct over the 16 fixed Section 1 items (4 pattern, 4 numerical, 4 deductive, 4 verbal)',
    retrieved_from = 'computed from 19 completed v2fcq assessments on the fixed 16-item Section 1, 2026-09-02 (replaces 31-completion July adaptive-pool norm of 80.68 / 8.72)',
    notes          = 'PROVISIONAL, N=19. REFRESH AT N>=50 on the same 16 items. NORM IS TIED TO THE ITEM SET: when harder Section 1 items ship, reset to a provisional seed and rebuild at N>=20 on the new set. Do not pool completions across item sets.',
    updated_by     = 'claude_migration_2026_09_02',
    updated_at     = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND facet = 'gma';

UPDATE public.hiregauge_facet_norms
SET ref_mean_0_100 = 2.0094,
    ref_sd_0_100   = 0.9345,
    retrieved_from = 'computed from the 16 of 19 completed v2fcq assessments at or above the 62.5% reasoning floor on the fixed 16-item Section 1, 2026-09-02 (replaces July adaptive-pool norm of 2.2380 / 1.0442)',
    notes          = 'PROVISIONAL, N=16. REFRESH AT N>=50 on the same 16 items; reset when the item set changes (same rule as gma). Higher correct-items-per-minute = better (natural direction, no inversion). USED INTERNALLY (v5.4/v5.5, 2026-08-14) to fold speed into the single gma percentile at a 3:1 accuracy:speed ratio -- not a standalone weighted role-fit input. Metric = correct-items-only timing per Peter directive; wrong answers contribute nothing in either direction.',
    updated_by     = 'claude_migration_2026_09_02',
    updated_at     = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND facet = 'gma_speed';

DO $chk$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM public.hiregauge_facet_norms
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND ((facet = 'gma' AND ref_mean_0_100 = 74.11) OR (facet = 'gma_speed' AND ref_mean_0_100 = 2.0094));
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'gma norm rebuild did not land on both rows (got %)', v_n;
  END IF;
END
$chk$;
