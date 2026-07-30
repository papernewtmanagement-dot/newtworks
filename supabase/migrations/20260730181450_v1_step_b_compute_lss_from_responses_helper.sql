-- Step B / Item 3 — helper: compute per-subtest LSS from v1 responses + apply
-- Groups hiregauge_candidate_responses by hiregauge_instrument_items.cognitive_domain.
-- Accuracy = count(is_correct=true) per domain. Speed = mean(answered_at - served_at)
-- in seconds per domain, or NULL when the candidate predates per-item timing.
-- Total accuracy = verbal + math + problem_solving. Only counts source items
-- (retest_of_item_number IS NULL) to align with retest-dedupe convention.

CREATE OR REPLACE FUNCTION public.apply_newtworks_v1_lss_to_candidate(p_candidate_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_agency_id uuid;
  v_verbal_acc int;
  v_math_acc int;
  v_ps_acc int;
  v_total_acc int;
  v_verbal_spd int;
  v_math_spd int;
  v_ps_spd int;
  v_verbal_n int;
  v_math_n int;
  v_ps_n int;
BEGIN
  SELECT agency_id INTO v_agency_id FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_agency_id IS NULL THEN
    RETURN jsonb_build_object('error','candidate_not_found','candidate_id', p_candidate_id);
  END IF;

  -- Accuracy: count of is_correct=true per domain, dedupe retest items via
  -- source-only join. Timing: mean seconds per domain, floor'd to int (NULL
  -- when no timing rows exist).
  SELECT
    count(*) FILTER (WHERE i.cognitive_domain = 'verbal'          AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'math'            AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'problem_solving' AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'verbal'         )::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'math'           )::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'problem_solving')::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'verbal'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'math'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'problem_solving'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int
  INTO v_verbal_acc, v_math_acc, v_ps_acc,
       v_verbal_n, v_math_n, v_ps_n,
       v_verbal_spd, v_math_spd, v_ps_spd
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON r.item_id = i.id
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'cognitive'
    AND i.cognitive_domain IS NOT NULL
    AND i.retest_of_item_number IS NULL;

  IF (v_verbal_n + v_math_n + v_ps_n) = 0 THEN
    RETURN jsonb_build_object(
      'candidate_id', p_candidate_id,
      'wrote', false,
      'reason', 'no_v1_cognitive_responses'
    );
  END IF;

  v_total_acc := v_verbal_acc + v_math_acc + v_ps_acc;

  UPDATE public.hiring_candidates SET
    lss_verbal_accuracy          = v_verbal_acc,
    lss_math_accuracy            = v_math_acc,
    lss_problem_solving_accuracy = v_ps_acc,
    lss_total_accuracy           = v_total_acc,
    lss_verbal_speed_seconds     = v_verbal_spd,
    lss_math_speed_seconds       = v_math_spd,
    lss_problem_solving_speed_seconds = v_ps_spd,
    updated_at = now()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object(
    'candidate_id', p_candidate_id,
    'wrote', true,
    'accuracy', jsonb_build_object(
      'verbal', jsonb_build_object('correct', v_verbal_acc, 'n', v_verbal_n),
      'math',   jsonb_build_object('correct', v_math_acc,   'n', v_math_n),
      'problem_solving', jsonb_build_object('correct', v_ps_acc, 'n', v_ps_n),
      'total', v_total_acc
    ),
    'speed_seconds', jsonb_build_object(
      'verbal', v_verbal_spd,
      'math',   v_math_spd,
      'problem_solving', v_ps_spd
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.apply_newtworks_v1_lss_to_candidate(uuid) IS
  'Step B / Item 3: aggregates a v1 candidate hiregauge_candidate_responses by cognitive_domain and writes the six flat LSS columns on hiring_candidates. Called by v1-assessment handleFinalize edge fn and used for backfill on pre-existing v1 candidates. Speed columns stay NULL when the candidate has no served_at/answered_at timing (predates per-item timing infrastructure).';
