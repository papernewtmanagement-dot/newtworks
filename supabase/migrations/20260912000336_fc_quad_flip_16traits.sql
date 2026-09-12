-- Phase 4 forced-choice personality: FLIP to the 16-trait set (2026-09-11, Peter: "change over everything now").
--
-- Before: ranking-block set quad75 current (items 701-775 active, 25 facets), quad48 registered but
--   inactive (items 776-823, 16 facets; migrations 20260911220312 and 20260911234748).
-- After:  quad75 retired, norm_status frozen -> its 43 locked candidates read the frozen
--         fcq_<facet>@quad75 rows (identical values); quad48 current, items 776-823 active,
--         701-775 inactive (responses stay scoreable; is_active governs serving only).
--         The 16 plain fcq_<facet> rows become the PROVISIONAL SEED for quad48 with the quad75
--         pool values carried over unchanged (closest available prior; the 2026-08-25 50/13
--         seed distorted percentiles for two weeks). hiregauge_fcq_norm_rebuild_current_set
--         replaces them at N >= 26 completed sittings on quad48 (trigger trg_fcq_norm_auto_rebuild).
-- Regression bar (Peter): zero verdict-band flips for the 27 old-set candidates. This migration
--   checks the stronger condition -- identical percentiles, construct scores, composite and
--   verdict for every one of them -- and rolls back on any difference.
-- Mid-sitting candidates (Peter 2026-09-11): no set lock in the endpoint. A candidate who has
--   not finished the old blocks is unlocked here and will be served the new blocks on resume;
--   their set is decided at finalize from what they actually answered (a mixed sitting resolves
--   to the current set). A candidate who finished all 75 old blocks stays locked to quad75.
-- The 9 plain rows of the dropped facets (anger, anxiety, avoid_goal_orientation, competitiveness,
--   fairness, greed_avoidance, prove_goal_orientation, sincerity, trust) are left in place; no
--   quad48 candidate has a raw for them, so they are unreachable. Deleting them is a separate call.

DO $$
DECLARE
  v_cur75 boolean; v_cur48 boolean;
  v_act75 int; v_act48 int;
  v_frozen int; v_mismatch int; v_locked48 int;
BEGIN
  SELECT is_current INTO v_cur75 FROM public.hiregauge_fcq_block_sets WHERE set_key = 'quad75';
  SELECT is_current INTO v_cur48 FROM public.hiregauge_fcq_block_sets WHERE set_key = 'quad48';
  IF v_cur75 IS DISTINCT FROM true OR v_cur48 IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'set registry not in pre-flip state: quad75 current=%, quad48 current=%', v_cur75, v_cur48;
  END IF;
  SELECT count(*) FILTER (WHERE is_active AND item_number BETWEEN 701 AND 775),
         count(*) FILTER (WHERE is_active AND item_number BETWEEN 776 AND 823)
    INTO v_act75, v_act48
  FROM public.hiregauge_instrument_items WHERE section = 'newtworks_v2_personality_fc_quad';
  IF v_act75 <> 75 OR v_act48 <> 0 THEN
    RAISE EXCEPTION 'items not in pre-flip state: % active in 701-775, % active in 776-823', v_act75, v_act48;
  END IF;
  SELECT count(*) INTO v_frozen FROM public.hiregauge_facet_norms
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND facet LIKE 'fcq\_%@quad75';
  SELECT count(*) INTO v_mismatch
  FROM public.hiregauge_facet_norms a
  JOIN public.hiregauge_facet_norms b ON b.agency_id = a.agency_id AND b.facet = a.facet || '@quad75'
  WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND a.facet LIKE 'fcq\_%' AND a.facet NOT LIKE '%@%'
    AND (a.ref_mean_0_100 <> b.ref_mean_0_100 OR a.ref_sd_0_100 <> b.ref_sd_0_100);
  IF v_frozen <> 25 OR v_mismatch <> 0 THEN
    RAISE EXCEPTION 'frozen quad75 rows not ready: % rows, % value mismatches', v_frozen, v_mismatch;
  END IF;
  SELECT count(*) INTO v_locked48 FROM public.hiring_candidates WHERE fcq_block_set = 'quad48';
  IF v_locked48 <> 0 THEN
    RAISE EXCEPTION '% candidates already locked to quad48', v_locked48;
  END IF;
END $$;

-- Snapshot of every old-set candidate before the switch.
CREATE TEMP TABLE fcq_flip_before AS
SELECT c.id,
       v.capability_score, v.character_score, v.commitment_score, v.composite, v.verdict,
       (SELECT jsonb_object_agg(p.facet, p.percentile)
          FROM public.hiregauge_candidate_facet_percentiles(c.id) p) AS pct
FROM public.hiring_candidates c
CROSS JOIN LATERAL public.verdict_assessment(c.id, NULL) v
WHERE c.assessment_source = 'v2fcq';

-- 1. Set registry: retire quad75 (norms frozen), activate quad48. Order matters for the
--    one-current-set index.
UPDATE public.hiregauge_fcq_block_sets
SET is_current = false, retired_at = now(), norm_status = 'frozen', updated_at = now(),
    notes = notes || ' RETIRED 2026-09-11 by migration fc_quad_flip_16traits; candidates locked here read fcq_<facet>@quad75.'
WHERE set_key = 'quad75';

UPDATE public.hiregauge_fcq_block_sets
SET is_current = true, activated_at = now(), updated_at = now(),
    notes = notes || ' ACTIVATED 2026-09-11 by migration fc_quad_flip_16traits; plain fcq_<facet> rows seeded from the quad75 pool values.'
WHERE set_key = 'quad48';

-- 2. Items. Deactivation is intentional (hiregauge_item_purge_guard escape hatch, documented there).
SET LOCAL hiregauge.allow_item_purge = 'on';

UPDATE public.hiregauge_instrument_items
SET is_active = false,
    notes = notes || ' RETIRED 2026-09-11 (flip to 16-trait set quad48, migration fc_quad_flip_16traits); responses stay scoreable.'
WHERE section = 'newtworks_v2_personality_fc_quad' AND item_number BETWEEN 701 AND 775;

UPDATE public.hiregauge_instrument_items
SET is_active = true,
    notes = replace(notes, 'inactive pending the flip', 'ACTIVE from 2026-09-11 (migration fc_quad_flip_16traits)')
WHERE section = 'newtworks_v2_personality_fc_quad' AND item_number BETWEEN 776 AND 823;

-- 3. Unlock candidates who had not finished the old blocks (their set is decided at finalize).
UPDATE public.hiring_candidates c
SET fcq_block_set = NULL
WHERE c.fcq_block_set = 'quad75'
  AND c.assessment_completed_at IS NULL
  AND (SELECT count(*) FROM public.hiregauge_candidate_responses r
       JOIN public.hiregauge_fcq_block_set_members m ON m.item_id = r.item_id AND m.set_key = 'quad75'
       WHERE r.candidate_id = c.id AND r.sitting = 1) < 75;

-- 4. The 16 plain rows: values unchanged, relabelled as the quad48 provisional seed.
UPDATE public.hiregauge_facet_norms
SET retrieved_from = 'PROVISIONAL SEED for ranking-block set quad48 (2026-09-11, migration fc_quad_flip_16traits): the quad75 pool values (N=26, 2026-09-10) carried over unchanged as the closest available prior. Replaced by hiregauge_fcq_norm_rebuild_current_set at N>=26 completed sittings on quad48.',
    notes = 'PROVISIONAL seed for block set quad48 (48 blocks, 16 facets, items 776-823). Values borrowed from quad75 (26 sittings on the 75-block set), not measured on these blocks: a 16-trait set changes each facet''s competitors, so percentiles on this set are approximate until the rebuild. Auto-rebuild at N>=26 (trg_fcq_norm_auto_rebuild); refresh at N>=50 by hand (p_force). Never pool across block sets.',
    updated_by = 'claude_migration_fc_quad_flip_16traits',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND facet IN ('fcq_achievement_striving', 'fcq_self_discipline', 'fcq_emotional_stability', 'fcq_dutifulness',
                'fcq_customer_orientation', 'fcq_self_efficacy', 'fcq_proactive_personality', 'fcq_cautiousness',
                'fcq_friendliness', 'fcq_cooperation', 'fcq_compassion', 'fcq_dispositional_optimism',
                'fcq_political_skill_networking', 'fcq_enterprising', 'fcq_assertiveness', 'fcq_learning_goal_orientation');

-- 5. Self-check and cache refresh.
DO $$
DECLARE
  v_before int; v_after int; v_diff int;
  v_act75 int; v_act48 int; v_unlocked int; v_seeded int;
  v_key text; v_rebuild jsonb;
BEGIN
  CREATE TEMP TABLE fcq_flip_after AS
  SELECT c.id,
         v.capability_score, v.character_score, v.commitment_score, v.composite, v.verdict,
         (SELECT jsonb_object_agg(p.facet, p.percentile)
            FROM public.hiregauge_candidate_facet_percentiles(c.id) p) AS pct
  FROM public.hiring_candidates c
  CROSS JOIN LATERAL public.verdict_assessment(c.id, NULL) v
  WHERE c.assessment_source = 'v2fcq';

  SELECT count(*) INTO v_before FROM fcq_flip_before;
  SELECT count(*) INTO v_after FROM fcq_flip_after;
  SELECT count(*) INTO v_diff
  FROM fcq_flip_before b
  FULL JOIN fcq_flip_after a ON a.id = b.id
  WHERE a.id IS NULL OR b.id IS NULL
     OR a.capability_score IS DISTINCT FROM b.capability_score
     OR a.character_score  IS DISTINCT FROM b.character_score
     OR a.commitment_score IS DISTINCT FROM b.commitment_score
     OR a.composite        IS DISTINCT FROM b.composite
     OR a.verdict          IS DISTINCT FROM b.verdict
     OR a.pct              IS DISTINCT FROM b.pct;
  IF v_before < 27 OR v_before <> v_after OR v_diff <> 0 THEN
    RAISE EXCEPTION 'regression check failed: % candidates before, % after, % changed', v_before, v_after, v_diff;
  END IF;

  SELECT count(*) FILTER (WHERE is_active AND item_number BETWEEN 701 AND 775),
         count(*) FILTER (WHERE is_active AND item_number BETWEEN 776 AND 823)
    INTO v_act75, v_act48
  FROM public.hiregauge_instrument_items WHERE section = 'newtworks_v2_personality_fc_quad';
  IF v_act75 <> 0 OR v_act48 <> 48 THEN
    RAISE EXCEPTION 'item activation wrong: % active in 701-775, % active in 776-823', v_act75, v_act48;
  END IF;

  v_key := public.hiregauge_facet_norm_key('v2fcq', 'quad75', 'compassion');
  IF v_key <> 'fcq_compassion@quad75' THEN
    RAISE EXCEPTION 'quad75 candidates would read %, expected fcq_compassion@quad75', v_key;
  END IF;
  v_key := public.hiregauge_facet_norm_key('v2fcq', 'quad48', 'compassion');
  IF v_key <> 'fcq_compassion' THEN
    RAISE EXCEPTION 'quad48 candidates would read %, expected fcq_compassion', v_key;
  END IF;

  SELECT count(*) INTO v_seeded FROM public.hiregauge_facet_norms
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND updated_by = 'claude_migration_fc_quad_flip_16traits';
  IF v_seeded <> 16 THEN
    RAISE EXCEPTION 'expected 16 seeded plain rows, relabelled %', v_seeded;
  END IF;

  v_rebuild := public.hiregauge_fcq_norm_rebuild_current_set('126794dd-25ff-47d2-a436-724499733365', false);
  IF (v_rebuild->>'rebuilt')::boolean OR v_rebuild->>'reason' <> 'waiting_for_n' OR v_rebuild->>'set_key' <> 'quad48' THEN
    RAISE EXCEPTION 'auto-rebuild should be waiting on quad48, got %', v_rebuild;
  END IF;

  SELECT count(*) INTO v_unlocked FROM public.hiring_candidates c
  WHERE c.fcq_block_set IS NULL AND EXISTS (
    SELECT 1 FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_fcq_block_set_members m ON m.item_id = r.item_id AND m.set_key = 'quad75'
    WHERE r.candidate_id = c.id);

  PERFORM public.hiregauge_refresh_scoring_cache('126794dd-25ff-47d2-a436-724499733365', 'all');

  INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'assessment_item_set_changed', 'info',
          'Ranking blocks switched to the 16-trait set',
          format('Stint 2 now serves 48 ranking blocks over 16 traits (items 776-823) instead of 75 blocks over 25 traits. Candidates who finished the old blocks keep their old norms (frozen as @quad75); %s candidates mid-way through the old blocks will get the new blocks when they come back. New-set norms are seeded from the old pool and rebuild automatically at 26 completed sittings.', v_unlocked),
          'hiring', false, false);
END $$;
