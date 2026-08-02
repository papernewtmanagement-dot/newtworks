-- Step 10: SJT per-construct scoring columns (0-100 scale per op-rule "Grading scale — 0-100 universal")
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_compliance_licensing_boundary smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_compliance_outbound_consent smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_composure_under_load smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_documentation_discipline smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_escalation_judgment smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_feedback_channel_discipline smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_honesty_integrity smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_peer_accountability smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_service_within_process smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_speaking_up_judgment smallint;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_total smallint;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hiring_candidates_sjt_scores_0_100') THEN
    ALTER TABLE public.hiring_candidates ADD CONSTRAINT hiring_candidates_sjt_scores_0_100 CHECK (
      (sjt_compliance_licensing_boundary IS NULL OR (sjt_compliance_licensing_boundary BETWEEN 0 AND 100)) AND
      (sjt_compliance_outbound_consent IS NULL OR (sjt_compliance_outbound_consent BETWEEN 0 AND 100)) AND
      (sjt_composure_under_load IS NULL OR (sjt_composure_under_load BETWEEN 0 AND 100)) AND
      (sjt_documentation_discipline IS NULL OR (sjt_documentation_discipline BETWEEN 0 AND 100)) AND
      (sjt_escalation_judgment IS NULL OR (sjt_escalation_judgment BETWEEN 0 AND 100)) AND
      (sjt_feedback_channel_discipline IS NULL OR (sjt_feedback_channel_discipline BETWEEN 0 AND 100)) AND
      (sjt_honesty_integrity IS NULL OR (sjt_honesty_integrity BETWEEN 0 AND 100)) AND
      (sjt_peer_accountability IS NULL OR (sjt_peer_accountability BETWEEN 0 AND 100)) AND
      (sjt_service_within_process IS NULL OR (sjt_service_within_process BETWEEN 0 AND 100)) AND
      (sjt_speaking_up_judgment IS NULL OR (sjt_speaking_up_judgment BETWEEN 0 AND 100)) AND
      (sjt_total IS NULL OR (sjt_total BETWEEN 0 AND 100))
    );
  END IF;
END $$;

-- Write-back function, same shape/pattern as apply_newtworks_gma_to_candidate.
-- Does NOT touch assessment_source (v2 finalize already sets it to 'v2' -- see
-- accompanying fix to apply_newtworks_gma_to_candidate for the bug this avoids).
CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_sjt_to_candidate(p_candidate_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_agency_id uuid;
  v jsonb;
  rec record;
  v_scores jsonb := '{}'::jsonb;
  v_total_sum numeric := 0;
  v_total_n int := 0;
  v_sql text;
BEGIN
  SELECT agency_id INTO v_agency_id FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_agency_id IS NULL THEN
    RETURN jsonb_build_object('error','candidate_not_found','candidate_id', p_candidate_id);
  END IF;

  CREATE TEMP TABLE _sjt_construct_scores (
    construct text,
    correct_n int,
    total_n int,
    pct numeric
  ) ON COMMIT DROP;

  INSERT INTO _sjt_construct_scores (construct, correct_n, total_n, pct)
  SELECT
    i.hypothesized_trait,
    count(*) FILTER (WHERE r.is_correct)::int,
    count(*)::int,
    ROUND(100.0 * count(*) FILTER (WHERE r.is_correct)::numeric / NULLIF(count(*), 0)::numeric, 0)
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON r.item_id = i.id
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'newtworks_v2_sjt'
    AND i.hypothesized_trait IS NOT NULL
  GROUP BY i.hypothesized_trait;

  IF NOT EXISTS (SELECT 1 FROM _sjt_construct_scores) THEN
    RETURN jsonb_build_object('candidate_id', p_candidate_id, 'wrote', false, 'reason', 'no_sjt_responses');
  END IF;

  SELECT sum(pct), count(*) INTO v_total_sum, v_total_n FROM _sjt_construct_scores;

  UPDATE public.hiring_candidates SET
    sjt_compliance_licensing_boundary = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_compliance_licensing_boundary'),
    sjt_compliance_outbound_consent   = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_compliance_outbound_consent'),
    sjt_composure_under_load          = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_composure_under_load'),
    sjt_documentation_discipline      = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_documentation_discipline'),
    sjt_escalation_judgment           = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_escalation_judgment'),
    sjt_feedback_channel_discipline   = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_feedback_channel_discipline'),
    sjt_honesty_integrity             = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_honesty_integrity'),
    sjt_peer_accountability           = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_peer_accountability'),
    sjt_service_within_process        = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_service_within_process'),
    sjt_speaking_up_judgment          = (SELECT pct::smallint FROM _sjt_construct_scores WHERE construct = 'sjt_speaking_up_judgment'),
    sjt_total                         = ROUND(v_total_sum / NULLIF(v_total_n,0), 0)::smallint,
    updated_at = now()
  WHERE id = p_candidate_id;

  SELECT jsonb_object_agg(construct, jsonb_build_object('pct', pct, 'correct', correct_n, 'n', total_n))
  INTO v_scores FROM _sjt_construct_scores;

  RETURN jsonb_build_object(
    'candidate_id', p_candidate_id,
    'wrote', true,
    'constructs', v_scores,
    'sjt_total', ROUND(v_total_sum / NULLIF(v_total_n,0), 0)
  );
END;
$function$;

-- Bug fix: apply_newtworks_gma_to_candidate was unconditionally overwriting
-- assessment_source to 'gma', which is not a valid value under
-- hiring_candidates_assessment_source_check (only 'v1'/'v2'/'cts'/null allowed)
-- and would have clobbered the 'v2' tag set by handleFinalizeV2 in the same
-- finalize call. Source of truth for assessment version is set once by the
-- v2 finalize path; this function should not touch it.
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
