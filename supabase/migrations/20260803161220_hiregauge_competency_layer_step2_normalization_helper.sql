-- Step 2 of Newtworks competency layer rebuild (confirmed 2026-08-02)
-- One function that returns every raw competency input already converted to 0-100,
-- given each input's own scale. This is the single source the 12 competency functions
-- (Step 3) read from -- no competency function re-derives GMA or SJT math itself.
--
-- What needs converting vs what doesn't (verified against live scoring functions
-- 2026-08-03, not assumed):
--   - The 21 personality trait columns on hiring_candidates are ALREADY 0-100.
--     compute_newtworks_v2_facets_as_row averages per-item percent-of-scale scores,
--     not raw sums. Pass through unchanged.
--   - gma_total_accuracy is a RAW COUNT out of 16 active items (4 subtests x 4 items,
--     confirmed via apply_newtworks_gma_to_candidate). Normalize /16*100.
--   - sjt_topic_detail stores RAW {correct, n} pairs per topic (confirmed via
--     apply_newtworks_v2_sjt_to_candidate), n=4 per active topic. Normalize each
--     topic /n*100.
-- Does NOT touch legacy lss_*_accuracy columns (raw item counts, different scale,
-- leaving per op-rule). Does NOT apply any penalty, floor, or multiplier -- pure
-- unit conversion only, per Step 2 spec.

CREATE OR REPLACE FUNCTION public.hiregauge_v2_normalized_inputs(p_candidate_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_row public.hiring_candidates%ROWTYPE;
  v_result jsonb;
  v_gma_pct numeric;
  v_topic jsonb;
  v_topic_key text;
  v_topic_n numeric;
BEGIN
  SELECT * INTO v_row FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  v_gma_pct := CASE WHEN v_row.gma_total_accuracy IS NULL THEN NULL
                     ELSE ROUND(v_row.gma_total_accuracy::numeric / 16.0 * 100.0, 1) END;

  v_result := jsonb_build_object(
    'achievement_striving',        v_row.achievement_striving,
    'anger',                       v_row.anger,
    'anxiety',                     v_row.anxiety,
    'assertiveness',               v_row.assertiveness,
    'cautiousness',                v_row.cautiousness,
    'compassion',                  v_row.compassion,
    'cooperation',                 v_row.cooperation,
    'customer_orientation',        v_row.customer_orientation,
    'dispositional_optimism',      v_row.dispositional_optimism,
    'dutifulness',                 v_row.dutifulness,
    'emotional_stability',         v_row.emotional_stability,
    'enterprising',                v_row.enterprising,
    'fairness',                    v_row.fairness,
    'friendliness',                v_row.friendliness,
    'greed_avoidance',             v_row.greed_avoidance,
    'political_skill_networking',  v_row.political_skill_networking,
    'proactive_personality',       v_row.proactive_personality,
    'self_discipline',             v_row.self_discipline,
    'self_efficacy',               v_row.self_efficacy,
    'sincerity',                   v_row.sincerity,
    'trust',                       v_row.trust,
    'gma_total',                   v_gma_pct
  );

  IF v_row.sjt_topic_detail IS NOT NULL THEN
    FOR v_topic_key IN SELECT jsonb_object_keys(v_row.sjt_topic_detail) LOOP
      v_topic := v_row.sjt_topic_detail -> v_topic_key;
      v_topic_n := NULLIF((v_topic ->> 'n')::numeric, 0);
      v_result := v_result || jsonb_build_object(
        v_topic_key,
        CASE WHEN v_topic_n IS NULL THEN NULL
             ELSE ROUND((v_topic ->> 'correct')::numeric / v_topic_n * 100.0, 1) END
      );
    END LOOP;
  END IF;

  RETURN v_result;
END;
$function$;
