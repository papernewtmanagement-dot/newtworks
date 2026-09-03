CREATE OR REPLACE FUNCTION public._newtworks_reasoning_gate(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
-- Raw percent-correct reasoning floor. Since 2026-09-02 the threshold comes
-- from hiregauge_gma_chance_floor for the candidate's item set: chance + 2 SD
-- computed from the real option counts of the items they answered (the
-- retired 2026-08 set is pinned to its ruled 62.5% by override). Semantics
-- unchanged from the 2026-08-05 design: fire only when a score cannot be
-- distinguished from guessing; the gated core caps the verdict at 'consider'
-- when it fires. Stays on raw percent-correct, not a percentile -- do not
-- convert it.
DECLARE
  v_norm jsonb;
  v_reasoning numeric;
  v_design_floor numeric;
  v_design_ceiling numeric;
  v_floor_info jsonb;
  v_floor numeric;
  v_floor_fired boolean := false;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_reasoning := (v_norm->>'gma_total')::numeric;

  v_floor_info := public.hiregauge_gma_chance_floor(p_candidate.id);
  v_floor := COALESCE((v_floor_info->>'floor_pct')::numeric, 62.5);

  SELECT intelligence_ideal_min, intelligence_ideal_max
    INTO v_design_floor, v_design_ceiling
    FROM public.hiregauge_role_ideal_ranges
    WHERE agency_id = p_candidate.agency_id
      AND role_category = p_role_category
      AND role_level = 'default';

  IF v_reasoning IS NOT NULL AND v_reasoning < v_floor THEN
    v_floor_fired := true;
  END IF;

  RETURN jsonb_build_object(
    'gate', 'reasoning_floor',
    'fired', v_floor_fired,
    'value', v_reasoning,
    'threshold', v_floor,
    'threshold_basis', COALESCE(v_floor_info->>'basis', 'chance_plus_2sd_provisional_2026_08_05'),
    'item_set', v_floor_info->>'set_key',
    'churn_risk_fired', false,
    'ceiling', NULL,
    'design_floor_t_scale', v_design_floor,
    'design_ceiling_t_scale', v_design_ceiling
  );
END;
$function$;
