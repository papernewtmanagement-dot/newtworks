-- Persist the integrity gate's shadow record + live soft flag alongside the
-- existing gate summary. hard_decline branch of v_summary kept (dead but
-- harmless -- hard_decline is now structurally always false) as a defensive
-- no-op rather than deleted, in case a future gate reintroduces a real
-- decline path.
CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_competency_gates_to_candidate(p_candidate_id uuid, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_candidate hiring_candidates;
  v_gated jsonb;
  v_summary text;
  v_integrity_detail jsonb;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  v_gated := public._newtworks_role_fit_gated_core(v_candidate, p_role_category);

  IF v_gated ? 'error' THEN
    RETURN v_gated;
  END IF;

  v_integrity_detail := v_gated->'gate_detail'->'integrity_decline';

  v_summary := CASE
    WHEN (v_gated->>'hard_decline')::boolean THEN 'integrity_decline'
    WHEN (v_gated->'gates_fired') @> '["critical_floor"]'::jsonb THEN 'critical_floor'
    WHEN (v_gated->'gates_fired') @> '["integrity_flag"]'::jsonb THEN 'integrity_flag'
    WHEN (v_gated->'gates_fired') @> '["reasoning_floor"]'::jsonb THEN 'reasoning_floor'
    ELSE NULL
  END;

  UPDATE public.hiring_candidates SET
    competency_gate_fired = v_summary,
    competency_gate_detail = v_gated->'gate_detail',
    churn_risk = (v_gated->>'churn_risk')::boolean,
    integrity_flag = COALESCE((v_integrity_detail->>'live_soft_flag')::boolean, false),
    integrity_gate_shadow_result = CASE
      WHEN (v_integrity_detail->>'shadow_would_decline')::boolean THEN 'would_decline'
      ELSE 'would_pass'
    END,
    integrity_gate_shadow_reason = v_integrity_detail->'conditions',
    updated_at = now()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object(
    'candidate_id', p_candidate_id, 'wrote', true,
    'role_category', p_role_category,
    'gate_fired', v_summary, 'churn_risk', (v_gated->>'churn_risk')::boolean,
    'integrity_flag', COALESCE((v_integrity_detail->>'live_soft_flag')::boolean, false),
    'integrity_gate_shadow_result', CASE
      WHEN (v_integrity_detail->>'shadow_would_decline')::boolean THEN 'would_decline'
      ELSE 'would_pass'
    END
  );
END;
$function$;
