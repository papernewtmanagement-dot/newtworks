CREATE OR REPLACE FUNCTION public.hiregauge_v2_normalized_inputs(p_candidate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_row public.hiring_candidates%ROWTYPE;
  v_result jsonb;
  v_gma_pct numeric;
  v_gma_n numeric;
  v_topic jsonb;
  v_topic_key text;
  v_topic_n numeric;
BEGIN
  SELECT * INTO v_row FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  -- Reasoning percentage. The denominator is the count of reasoning items
  -- this candidate actually answered, NOT a hardcoded item-bank size. A
  -- hardcoded divisor silently breaks whenever the active item set changes
  -- (it produced >100% scores while three stray items were live at stint 2),
  -- and would retroactively re-scale historical candidates if the bank is
  -- ever widened. Filter is deliberately identical to the one in
  -- apply_newtworks_gma_to_candidate -- same population on both sides of
  -- the division, retest items excluded from both.
  SELECT count(*)::numeric
    INTO v_gma_n
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'newtworks_v2_cognitive_gma'
    AND i.cognitive_domain IS NOT NULL
    AND i.retest_of_item_number IS NULL;

  v_gma_pct := CASE
                 WHEN v_row.gma_total_accuracy IS NULL THEN NULL
                 WHEN COALESCE(v_gma_n, 0) = 0 THEN NULL
                 ELSE ROUND(v_row.gma_total_accuracy::numeric / v_gma_n * 100.0, 1)
               END;

  v_result := jsonb_build_object(
    'achievement_striving',        v_row.achievement_striving,
    'anger',                       v_row.anger,
    'anxiety',                     v_row.anxiety,
    'assertiveness',               v_row.assertiveness,
    'avoid_goal_orientation',      v_row.avoid_goal_orientation,
    'cautiousness',                v_row.cautiousness,
    'compassion',                  v_row.compassion,
    'competitiveness',             v_row.competitiveness,
    'cooperation',                 v_row.cooperation,
    'customer_orientation',        v_row.customer_orientation,
    'dispositional_optimism',      v_row.dispositional_optimism,
    'dutifulness',                 v_row.dutifulness,
    'emotional_stability',         v_row.emotional_stability,
    'enterprising',                v_row.enterprising,
    'fairness',                    v_row.fairness,
    'friendliness',                v_row.friendliness,
    'greed_avoidance',             v_row.greed_avoidance,
    'learning_goal_orientation',   v_row.learning_goal_orientation,
    'political_skill_networking',  v_row.political_skill_networking,
    'proactive_personality',       v_row.proactive_personality,
    'prove_goal_orientation',      v_row.prove_goal_orientation,
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
