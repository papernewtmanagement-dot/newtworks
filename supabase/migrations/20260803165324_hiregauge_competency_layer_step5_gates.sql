-- Step 5: gates. Per Peter's correction — 21 critical-tier floors (gate b),
-- one optional global integrity DECLINE threshold (gate a, no-ops when
-- unset), reasoning floor/ceiling from hiregauge_role_ideal_ranges
-- (gates c/d). Every fired gate is persisted with its tripping value
-- (op-rule "Newtworks competency floors" requirement #5 -- these floors are
-- priors, not calibrations, and need to be recalibratable from real data).

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS competency_gate_fired text,
  ADD COLUMN IF NOT EXISTS competency_gate_detail jsonb,
  ADD COLUMN IF NOT EXISTS churn_risk boolean;

COMMENT ON COLUMN public.hiring_candidates.competency_gate_fired IS
'Which Step 5 gate fired for this candidate''s best-fit role, if any:
integrity_decline | critical_floor | reasoning_floor | null. NOT a
free-text field -- one of these four values or null. See
competency_gate_detail for the full trace (all breaches, values,
thresholds), not just the summary label.';
COMMENT ON COLUMN public.hiring_candidates.competency_gate_detail IS
'Full jsonb trace of every gate check run for the candidate''s best-fit
role: which fired, which did not, actual values vs thresholds. Persisted
so the 21 provisional floors (set 2026-08-02, zero candidates scored yet)
can be recalibrated from real outcomes later.';
COMMENT ON COLUMN public.hiring_candidates.churn_risk IS
'Gate (d): reasoning score above the role ceiling. Means likely-to-leave
(overqualified/flight-risk), NOT likely-to-underperform. Never affects any
score -- display-only flag.';

-- Gate (a): global integrity DECLINE floor. Role-agnostic. Peter has not
-- set this threshold (deliberately -- it hard-declines with no human
-- review, not Claude's call). Reads
-- hiregauge_competency_floors(competency_name='integrity_global_decline',
-- role_category IS NULL). No row / NULL floor = gate no-ops safely, never
-- defaults to a number.
CREATE OR REPLACE FUNCTION public._newtworks_integrity_decline_gate(p_candidate hiring_candidates)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_integrity jsonb;
  v_threshold numeric;
  v_value numeric;
  v_fired boolean := false;
BEGIN
  SELECT floor INTO v_threshold FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id
      AND competency_name = 'integrity_global_decline'
      AND role_category IS NULL;

  v_integrity := public.newtworks_competency_integrity(p_candidate);
  v_value := (v_integrity->>'adjusted')::numeric;

  IF v_threshold IS NOT NULL AND v_value IS NOT NULL AND v_value < v_threshold THEN
    v_fired := true;
  END IF;

  RETURN jsonb_build_object(
    'gate', 'integrity_decline',
    'fired', v_fired,
    'value', v_value,
    'threshold', v_threshold,
    'threshold_set', v_threshold IS NOT NULL
  );
END;
$fn$;

COMMENT ON FUNCTION public._newtworks_integrity_decline_gate(hiring_candidates) IS
'Gate (a). Role-agnostic hard decline on integrity below a global floor.
Threshold is Peter''s call, deliberately unset as of 2026-08-03 -- reads
hiregauge_competency_floors(competency_name=''integrity_global_decline'',
role_category IS NULL); no row present = gate always returns fired=false.
Recommendation on file when Peter is ready to set it (~40, low, catches
only active endorsement of dishonest positions): see persistent_memory
operational_rule "Newtworks competency floors — 21 per-role critical
floors + rationale".';

-- Gates (c) and (d): reasoning floor (cap to consider) and ceiling
-- (churn_risk flag, no score impact). Reads hiregauge_role_ideal_ranges,
-- unchanged from the LSS-era design -- only what it is applied to changed.
CREATE OR REPLACE FUNCTION public._newtworks_reasoning_gate(p_candidate hiring_candidates, p_role_category text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_norm jsonb;
  v_reasoning numeric;
  v_floor numeric;
  v_ceiling numeric;
  v_floor_fired boolean := false;
  v_ceiling_fired boolean := false;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_reasoning := (v_norm->>'gma_total')::numeric;

  SELECT intelligence_ideal_min, intelligence_ideal_max
    INTO v_floor, v_ceiling
    FROM public.hiregauge_role_ideal_ranges
    WHERE agency_id = p_candidate.agency_id
      AND role_category = p_role_category
      AND role_level = 'default';

  IF v_reasoning IS NOT NULL AND v_floor IS NOT NULL AND v_reasoning < v_floor THEN
    v_floor_fired := true;
  END IF;
  IF v_reasoning IS NOT NULL AND v_ceiling IS NOT NULL AND v_reasoning > v_ceiling THEN
    v_ceiling_fired := true;
  END IF;

  RETURN jsonb_build_object(
    'gate', 'reasoning_floor',
    'fired', v_floor_fired,
    'value', v_reasoning,
    'threshold', v_floor,
    'churn_risk_fired', v_ceiling_fired,
    'ceiling', v_ceiling
  );
END;
$fn$;

COMMENT ON FUNCTION public._newtworks_reasoning_gate(hiring_candidates, text) IS
'Gates (c) and (d). Floor breach caps verdict at consider (measurement
precision at cut scores, cognitive load under floor -- Kane 1996, Sweller
1988). Ceiling breach sets churn_risk (likely-to-leave, not
likely-to-underperform) and touches no score -- soft-threshold empirical
support Zhou, Kuncel & Sackett 2024, linearity caveat Coward & Sackett
1990. Bands from hiregauge_role_ideal_ranges, unchanged from the retired
LSS-era design.';

-- Gate (b) + full gated wrapper. Any CRITICAL-tier competency below its
-- per-role floor caps the verdict at consider. Important/supporting tiers
-- have no floor by design (op-rule "Newtworks competency floors").
CREATE OR REPLACE FUNCTION public._newtworks_role_fit_gated_core(p_candidate hiring_candidates, p_role_category text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_fit jsonb;
  v_comp jsonb;
  v_comp_name text;
  v_critical_breaches jsonb := '[]'::jsonb;
  v_integrity_gate jsonb;
  v_reasoning_gate jsonb;
  v_gates_fired text[] := ARRAY[]::text[];
  v_verdict_cap text := NULL;
  v_hard_decline boolean := false;
BEGIN
  v_fit := public._newtworks_role_fit_core(p_candidate, p_role_category);

  IF v_fit ? 'error' THEN
    RETURN v_fit;
  END IF;

  -- Gate (b): scan every competency in the fit result; only act on
  -- tier='critical' rows with a floor set and adjusted below it.
  FOR v_comp_name, v_comp IN SELECT * FROM jsonb_each(v_fit->'competencies') LOOP
    IF v_comp->>'tier' = 'critical'
       AND (v_comp->>'floor') IS NOT NULL
       AND (v_comp->>'adjusted') IS NOT NULL
       AND (v_comp->>'adjusted')::numeric < (v_comp->>'floor')::numeric
    THEN
      v_critical_breaches := v_critical_breaches || jsonb_build_array(jsonb_build_object(
        'competency', v_comp_name,
        'value', (v_comp->>'adjusted')::numeric,
        'threshold', (v_comp->>'floor')::numeric
      ));
    END IF;
  END LOOP;

  IF jsonb_array_length(v_critical_breaches) > 0 THEN
    v_gates_fired := array_append(v_gates_fired, 'critical_floor');
    v_verdict_cap := 'consider';
  END IF;

  -- Gate (a)
  v_integrity_gate := public._newtworks_integrity_decline_gate(p_candidate);
  IF (v_integrity_gate->>'fired')::boolean THEN
    v_gates_fired := array_append(v_gates_fired, 'integrity_decline');
    v_hard_decline := true;
  END IF;

  -- Gates (c)/(d)
  v_reasoning_gate := public._newtworks_reasoning_gate(p_candidate, p_role_category);
  IF (v_reasoning_gate->>'fired')::boolean THEN
    v_gates_fired := array_append(v_gates_fired, 'reasoning_floor');
    v_verdict_cap := 'consider';
  END IF;

  RETURN v_fit || jsonb_build_object(
    'gates_fired', to_jsonb(v_gates_fired),
    'verdict_cap', CASE WHEN v_hard_decline THEN 'decline' ELSE v_verdict_cap END,
    'hard_decline', v_hard_decline,
    'churn_risk', COALESCE((v_reasoning_gate->>'churn_risk_fired')::boolean, false),
    'gate_detail', jsonb_build_object(
      'critical_floor_breaches', v_critical_breaches,
      'integrity_decline', v_integrity_gate,
      'reasoning', v_reasoning_gate
    )
  );
END;
$fn$;

COMMENT ON FUNCTION public._newtworks_role_fit_gated_core(hiring_candidates, text) IS
'Step 5 complete: wraps _newtworks_role_fit_core (Step 4, unchanged) with
gates (a)-(d). Gates cap or decline the VERDICT, never alter the fit_score
number itself (per the 12-competency op-rule: "A GATE, not a score
penalty. No exponential decay anywhere."). hard_decline=true means gate
(a) fired (currently always false -- threshold unset). verdict_cap is the
ceiling on what hiring_evaluate_candidate/verdict layers should allow,
independent of any raw score.';

-- The 7 public role_fit functions now return the gated result.
CREATE OR REPLACE FUNCTION public.newtworks_role_fit_sales_outbound(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_gated_core(p_candidate, 'sales_outbound'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_sales_inbound(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_gated_core(p_candidate, 'sales_inbound'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_sales_in_book(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_gated_core(p_candidate, 'sales_in_book'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_retention_escalation(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_gated_core(p_candidate, 'retention_escalation'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_retention_reception(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_gated_core(p_candidate, 'retention_reception'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_retention_support(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_gated_core(p_candidate, 'retention_support'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_aspirant(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_gated_core(p_candidate, 'aspirant'); $fn$;

-- Writer: persists which gate fired + full detail for the candidate's
-- current best-fit role. Called at finalize, alongside apply_newtworks_gma_
-- to_candidate / apply_newtworks_v2_sjt_to_candidate.
CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_competency_gates_to_candidate(p_candidate_id uuid, p_role_category text)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_candidate hiring_candidates;
  v_gated jsonb;
  v_summary text;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  v_gated := public._newtworks_role_fit_gated_core(v_candidate, p_role_category);

  IF v_gated ? 'error' THEN
    RETURN v_gated;
  END IF;

  v_summary := CASE
    WHEN (v_gated->>'hard_decline')::boolean THEN 'integrity_decline'
    WHEN (v_gated->'gates_fired') @> '["critical_floor"]'::jsonb THEN 'critical_floor'
    WHEN (v_gated->'gates_fired') @> '["reasoning_floor"]'::jsonb THEN 'reasoning_floor'
    ELSE NULL
  END;

  UPDATE public.hiring_candidates SET
    competency_gate_fired = v_summary,
    competency_gate_detail = v_gated->'gate_detail',
    churn_risk = (v_gated->>'churn_risk')::boolean,
    updated_at = now()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object(
    'candidate_id', p_candidate_id, 'wrote', true,
    'role_category', p_role_category,
    'gate_fired', v_summary, 'churn_risk', (v_gated->>'churn_risk')::boolean
  );
END;
$fn$;

COMMENT ON FUNCTION public.apply_newtworks_v2_competency_gates_to_candidate(uuid, text) IS
'Writer for Step 5''s persistence requirement. Computes gates for the given
role (normally the candidate''s best-fit role) and writes
competency_gate_fired/competency_gate_detail/churn_risk onto the
hiring_candidates row. NOT yet wired into the v1-assessment edge function
finalize step -- needs to be added alongside the other apply_* calls
(Step 8/9 follow-through).';
