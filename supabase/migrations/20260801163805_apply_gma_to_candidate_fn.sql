CREATE OR REPLACE FUNCTION public.apply_newtworks_gma_to_candidate(p_candidate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_agency_id uuid;
  v_pattern_acc int;   v_deductive_acc int;   v_numerical_acc int;   v_verbal_acc int;
  v_pattern_n int;     v_deductive_n int;     v_numerical_n int;     v_verbal_n int;
  v_pattern_spd int;   v_deductive_spd int;   v_numerical_spd int;   v_verbal_spd int;
  v_total_acc int;
BEGIN
  SELECT agency_id INTO v_agency_id FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_agency_id IS NULL THEN
    RETURN jsonb_build_object('error','candidate_not_found','candidate_id', p_candidate_id);
  END IF;

  SELECT
    count(*) FILTER (WHERE i.cognitive_domain = 'gma_pattern'   AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'gma_deductive' AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'gma_numerical' AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'gma_verbal'    AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'gma_pattern'  )::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'gma_deductive')::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'gma_numerical')::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'gma_verbal'   )::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'gma_pattern'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'gma_deductive'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'gma_numerical'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'gma_verbal'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int
  INTO v_pattern_acc, v_deductive_acc, v_numerical_acc, v_verbal_acc,
       v_pattern_n, v_deductive_n, v_numerical_n, v_verbal_n,
       v_pattern_spd, v_deductive_spd, v_numerical_spd, v_verbal_spd
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON r.item_id = i.id
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'newtworks_v2_cognitive_gma'
    AND i.cognitive_domain IS NOT NULL
    AND i.retest_of_item_number IS NULL;

  IF (v_pattern_n + v_deductive_n + v_numerical_n + v_verbal_n) = 0 THEN
    RETURN jsonb_build_object(
      'candidate_id', p_candidate_id,
      'wrote', false,
      'reason', 'no_gma_cognitive_responses'
    );
  END IF;

  -- Same "not asked" vs "asked and missed" distinction as the legacy LSS writer:
  -- NULL out a domain the candidate never saw, don't store a false 0.
  IF v_pattern_n   = 0 THEN v_pattern_acc   := NULL; END IF;
  IF v_deductive_n = 0 THEN v_deductive_acc := NULL; END IF;
  IF v_numerical_n = 0 THEN v_numerical_acc := NULL; END IF;
  IF v_verbal_n    = 0 THEN v_verbal_acc    := NULL; END IF;

  v_total_acc := COALESCE(v_pattern_acc, 0) + COALESCE(v_deductive_acc, 0)
               + COALESCE(v_numerical_acc, 0) + COALESCE(v_verbal_acc, 0);

  UPDATE public.hiring_candidates SET
    gma_pattern_accuracy          = v_pattern_acc,
    gma_deductive_accuracy        = v_deductive_acc,
    gma_numerical_accuracy        = v_numerical_acc,
    gma_verbal_accuracy           = v_verbal_acc,
    gma_total_accuracy            = v_total_acc,
    gma_pattern_speed_seconds     = v_pattern_spd,
    gma_deductive_speed_seconds   = v_deductive_spd,
    gma_numerical_speed_seconds   = v_numerical_spd,
    gma_verbal_speed_seconds      = v_verbal_spd,
    assessment_source             = 'gma',
    updated_at = now()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object(
    'candidate_id', p_candidate_id,
    'wrote', true,
    'accuracy', jsonb_build_object(
      'pattern', jsonb_build_object('correct', v_pattern_acc, 'n', v_pattern_n),
      'deductive', jsonb_build_object('correct', v_deductive_acc, 'n', v_deductive_n),
      'numerical', jsonb_build_object('correct', v_numerical_acc, 'n', v_numerical_n),
      'verbal', jsonb_build_object('correct', v_verbal_acc, 'n', v_verbal_n),
      'total', v_total_acc
    ),
    'speed_seconds', jsonb_build_object(
      'pattern', v_pattern_spd, 'deductive', v_deductive_spd,
      'numerical', v_numerical_spd, 'verbal', v_verbal_spd
    )
  );
END;
$function$;
