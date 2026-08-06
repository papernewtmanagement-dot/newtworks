CREATE OR REPLACE FUNCTION public.apply_interview_plan(p_candidate_id uuid, p_target_minutes numeric DEFAULT 60, p_force boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_row public.hiring_candidates%ROWTYPE;
  v_plan jsonb;
  v_sections jsonb := '[]'::jsonb;
  v_construct text;
  v_probes jsonb;
  v_construct_label text;
  v_focus_label text;
  v_probe jsonb;
  v_final jsonb;
BEGIN
  SELECT * INTO v_row FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  -- Don't overwrite a recent plan unless forced (same rule as existing pipeline)
  IF NOT p_force
     AND v_row.custom_probes IS NOT NULL
     AND v_row.custom_probes_generated_at IS NOT NULL
     AND v_row.custom_probes_generated_at > (now() - interval '24 hours')
  THEN
    RETURN v_row.custom_probes;
  END IF;

  v_plan := public.build_interview_plan(p_candidate_id, p_target_minutes);

  IF v_plan ? 'error' THEN
    RETURN v_plan;
  END IF;

  -- Group probes into sections by construct, in order Capability / Character / Commitment,
  -- internally sorted by priority DESC (i.e. the order build_interview_plan already
  -- placed them in per construct, since it walked universal_core -> triggered -> stretch
  -- each already ordered priority DESC).
  FOR v_construct IN SELECT unnest(ARRAY['capability', 'character', 'commitment']) LOOP
    v_probes := '[]'::jsonb;

    FOR v_probe IN SELECT * FROM jsonb_array_elements(v_plan->'questions') e WHERE e->>'construct' = v_construct
    LOOP
      v_construct_label := initcap(v_construct);
      v_focus_label := v_construct_label || ' — ' || replace(initcap(replace(v_probe->>'subconstruct', '_', ' ')), ' ', ' ');

      v_probes := v_probes || jsonb_build_object(
        'source', 'bank:' || (v_probe->>'code'),
        'question', v_probe->>'question_text',
        'listen_for', v_probe->>'listen_for',
        'concern', v_probe->>'concern',
        'followups', COALESCE(v_probe->'followups', '[]'::jsonb),
        'construct', v_probe->>'construct',
        'est_minutes', (v_probe->>'est_minutes')::numeric
      );
    END LOOP;

    IF jsonb_array_length(v_probes) > 0 THEN
      v_sections := v_sections || jsonb_build_object(
        'focus', v_construct_label || ' — mixed', -- overwritten below per subconstruct grouping
        'probes', v_probes
      );
    END IF;
  END LOOP;

  -- Rebuild sections properly: one section per construct (not per subconstruct), matching
  -- how CandidateDetail.jsx currently renders custom_probes.sections (focus = human label,
  -- probes = flat array). Group by construct only, per handoff spec.
  v_sections := '[]'::jsonb;
  FOR v_construct IN SELECT unnest(ARRAY['capability', 'character', 'commitment']) LOOP
    v_probes := '[]'::jsonb;

    FOR v_probe IN SELECT * FROM jsonb_array_elements(v_plan->'questions') e WHERE e->>'construct' = v_construct
    LOOP
      v_probes := v_probes || jsonb_build_object(
        'source', 'bank:' || (v_probe->>'code'),
        'question', v_probe->>'question_text',
        'listen_for', v_probe->>'listen_for',
        'concern', v_probe->>'concern',
        'followups', COALESCE(v_probe->'followups', '[]'::jsonb),
        'construct', v_probe->>'construct',
        'est_minutes', (v_probe->>'est_minutes')::numeric
      );
    END LOOP;

    IF jsonb_array_length(v_probes) > 0 THEN
      v_sections := v_sections || jsonb_build_object(
        'focus', initcap(v_construct),
        'probes', v_probes
      );
    END IF;
  END LOOP;

  v_final := jsonb_build_object(
    'version', 'interview-bank-v1',
    'generated_by', 'build_interview_plan',
    'generated_at', now(),
    'target_minutes', p_target_minutes,
    'sections', v_sections,
    'plan_meta', jsonb_build_object(
      'budget_exceeded', v_plan->'budget_exceeded',
      'overage_minutes', v_plan->'overage_minutes',
      'unfit_triggers', v_plan->'unfit_triggers'
    )
  );

  UPDATE public.hiring_candidates
  SET custom_probes = v_final,
      custom_probes_generated_at = now()
  WHERE id = p_candidate_id;

  RETURN v_final;
END;
$function$;
