-- Fix the Ass Check 3 audit finding: _newtworks_reasoning_gate compared raw
-- percent-correct on the 16-item GMA section against hiregauge_role_ideal_ranges
-- thresholds (floors 50-70, ceilings 80-93) that were explicitly calibrated for a
-- standardized composite "mean ~50, SD ~15" (their own docstrings say so). Raw
-- percent-correct is a different metric: guessing alone averages 37.5%, so the old
-- floors would cap most real candidates at 'consider' and the ceiling/churn flag
-- was nearly unreachable. With ZERO live GMA distributions, the only honest
-- provisional threshold is chance-anchored (the house method locked in *Ass Plan 2
-- for the stint-1 exit gates): fire the floor only when a score cannot be
-- distinguished from guessing.
--
-- Derivation from the live bank (2026-08-05): chance rates 0.5/0.3333/0.5/0.1667
-- x 4 items each => expected guessing score 6/16, variance 3.44, SD 1.86 items.
-- Guessing + 2 SD = 9.7 items => a candidate at <= 9/16 (56.25%) cannot be
-- rejected as a guesser at ~95% confidence. Provisional floor therefore fires
-- when gma_total percent < 62.5 (i.e., fewer than 10 of 16 correct).
-- Ceiling / churn flag is NEUTRAL (never fires) until real distributions exist --
-- "extreme outlier" cannot be defined on percent-correct without norms.
-- The per-role design thresholds are NOT deleted: hiregauge_role_ideal_ranges is
-- untouched and both design values are returned in the gate detail, so the n>=30
-- recalibration (29 CFR Part 1607 local-validation step) can restore per-role
-- differentiation on a properly normed scale. Recompute this provisional floor if
-- the active GMA bank changes size or composition.
CREATE OR REPLACE FUNCTION public._newtworks_reasoning_gate(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_norm jsonb;
  v_reasoning numeric;
  v_design_floor numeric;
  v_design_ceiling numeric;
  v_floor numeric := 62.5;  -- provisional, chance + 2 SD on the current 16-item bank
  v_floor_fired boolean := false;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_reasoning := (v_norm->>'gma_total')::numeric;

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
    'threshold_basis', 'chance_plus_2sd_provisional_2026_08_05',
    'churn_risk_fired', false,
    'ceiling', NULL,
    'design_floor_t_scale', v_design_floor,
    'design_ceiling_t_scale', v_design_ceiling
  );
END;
$function$;
