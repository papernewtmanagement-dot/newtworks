CREATE TABLE IF NOT EXISTS hiregauge_role_fit_pre_facet_snapshot (
  agency_id uuid,
  candidate_id uuid,
  role_category text,
  fit_score numeric,
  is_best_fit boolean,
  model_tag text DEFAULT 'competency_v4_pre_facet',
  captured_at timestamptz DEFAULT now(),
  UNIQUE(agency_id, candidate_id, role_category)
);

INSERT INTO hiregauge_role_fit_pre_facet_snapshot (agency_id, candidate_id, role_category, fit_score, is_best_fit)
SELECT
  hc.agency_id,
  hc.id,
  r.role_category,
  (CASE r.role_category
    WHEN 'sales_outbound'       THEN b.sales_outbound_fit_score
    WHEN 'sales_inbound'        THEN b.sales_inbound_fit_score
    WHEN 'sales_in_book'        THEN b.sales_in_book_fit_score
    WHEN 'retention_reception'  THEN b.retention_reception_fit_score
    WHEN 'retention_escalation' THEN b.retention_escalation_fit_score
    WHEN 'retention_support'    THEN b.retention_support_fit_score
    WHEN 'aspirant'             THEN b.aspirant_fit_score
  END)::numeric,
  (r.role_category = b.best_role)
FROM public.hiring_candidates hc
CROSS JOIN (VALUES
  ('sales_outbound'),('sales_inbound'),('sales_in_book'),
  ('retention_reception'),('retention_escalation'),('retention_support'),
  ('aspirant')
) AS r(role_category)
CROSS JOIN LATERAL public.assessment_best_fit_role(hc.id) b
WHERE hc.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND hc.achievement_striving IS NOT NULL
  -- Standing exclusion: manual test-candidate row, never touched by any rebuild/recompute
  AND hc.id <> '97a56442-0be5-41f4-a2ba-c4b2f01f079a'
ON CONFLICT (agency_id, candidate_id, role_category) DO NOTHING;
CREATE OR REPLACE FUNCTION public._newtworks_role_fit_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
model_tag: role_fit_v5_0_facet_direct_2026_08_06

Facet-direct role-fit core. Replaces the 13-competency composite pipeline
(newtworks_competency_*) with a direct weighted sum over 27 inputs (25
personality/goal-orientation facets, computed as percentiles against
hiregauge_facet_norms, plus gma and sjt already expressed 0-100) using
per-role weights from hiregauge_role_facet_weights.

Design grounding:
- Synthetic/composite validity over single-predictor validity: Lawshe 1952;
  Scherbaum 2005 Pers Psych 58:481-515; Johnson & Carter 2010 Pers Psych 63.
- Equal/unit weighting competitive with regression weighting under
  real-world noise: Wainer 1976; Dawes 1979.
- Facet-level (vs domain-level) prediction: Dudley, Orvis, Lebiecki &
  Cortina 2006 JAP 91:40-57.
- Two non-linear ceiling folds (assertiveness/sales_outbound,
  cautiousness/retention_reception+retention_support): Grant 2013 Psych Sci
  24:1024-1030 (GR13); Le, Oh, Robbins, Ilies, Holland & Westrick 2011 JAP
  96:113-133 (LE11). No other ceiling folds exist -- do not add more.
- Norms-referencing approach: Johnson 2014 J Res Pers 51:78-89.

GMA input: denominator is the LIVE count of scoreable GMA items this
candidate answered (hiregauge_candidate_responses joined to
hiregauge_instrument_items, section='newtworks_v2_cognitive_gma',
cognitive_domain IS NOT NULL, retest_of_item_number IS NULL) -- same filter
as apply_newtworks_gma_to_candidate, same population on both sides of the
division. Never a hardcoded item-bank size (hiregauge_v2_normalized_inputs'
docstring records a hardcoded 16 producing >100% scores once the item bank
grew past that count while three stray items were live at stint 2; the bank
now holds 75 scoreable items under adaptive serving).

SJT input: sjt_score used directly, already 0-100, no transformation.

Fit formula: fit = clamp( SUM(weight_i * effective_i) / SUM(weight_i WHERE
weight_i > 0 AND value_i IS NOT NULL), 0, 100 ). A NULL-valued input (no
percentile norm, e.g. the deliberately-parked competitiveness facet, or a
raw score the candidate never produced) is excluded from both the numerator
and the positive-weight denominator, and listed in missing_inputs. Negative-
weight inputs (e.g. anger) subtract in the numerator without inflating the
denominator.
*/
DECLARE
  v_input_names text[] := ARRAY[
    'achievement_striving','self_discipline','emotional_stability','dutifulness',
    'customer_orientation','self_efficacy','proactive_personality','cautiousness',
    'anxiety','friendliness','anger','cooperation','trust','dispositional_optimism',
    'political_skill_networking','enterprising','sincerity','fairness','greed_avoidance',
    'assertiveness','compassion','competitiveness','learning_goal_orientation',
    'prove_goal_orientation','avoid_goal_orientation','gma','sjt'
  ];
  v_candidate_json jsonb;
  v_name text;
  v_raw numeric;
  v_value numeric;
  v_eff numeric;
  v_weight numeric;
  v_citation text;
  v_gma_n numeric;
  v_weighted_sum numeric := 0;
  v_denom numeric := 0;
  v_detail jsonb := '{}'::jsonb;
  v_missing text[] := ARRAY[]::text[];
  v_fit numeric;
BEGIN
  IF p_candidate.achievement_striving IS NULL THEN
    RETURN jsonb_build_object('error', 'no_trait_data', 'role_category', p_role_category);
  END IF;

  v_candidate_json := to_jsonb(p_candidate);

  FOREACH v_name IN ARRAY v_input_names LOOP
    SELECT weight, citation INTO v_weight, v_citation
      FROM public.hiregauge_role_facet_weights
      WHERE agency_id = p_candidate.agency_id
        AND role_category = p_role_category
        AND input_name = v_name;
    v_weight := COALESCE(v_weight, 0);

    IF v_name = 'gma' THEN
      SELECT count(*)::numeric INTO v_gma_n
        FROM public.hiregauge_candidate_responses r
        JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
        WHERE r.candidate_id = p_candidate.id
          AND i.section = 'newtworks_v2_cognitive_gma'
          AND i.cognitive_domain IS NOT NULL
          AND i.retest_of_item_number IS NULL;
      v_value := CASE
        WHEN p_candidate.gma_total_accuracy IS NULL OR COALESCE(v_gma_n, 0) = 0 THEN NULL
        ELSE ROUND(p_candidate.gma_total_accuracy::numeric / v_gma_n * 100.0)
      END;
    ELSIF v_name = 'sjt' THEN
      v_value := p_candidate.sjt_score;
    ELSE
      v_raw := (v_candidate_json->>v_name)::numeric;
      IF v_raw IS NULL THEN
        v_value := NULL;
      ELSE
        v_value := public.hiregauge_facet_percentile(p_candidate.agency_id, v_name, v_raw);
      END IF;
    END IF;

    IF v_value IS NULL THEN
      v_missing := array_append(v_missing, v_name);
      v_detail := v_detail || jsonb_build_object(v_name, jsonb_build_object(
        'value', NULL, 'effective', NULL, 'weight', v_weight, 'basis', v_citation));
      CONTINUE;
    END IF;

    v_eff := v_value;
    IF p_role_category = 'sales_outbound' AND v_name = 'assertiveness' AND v_eff > 75 THEN
      v_eff := 75 - (v_eff - 75) * 0.5;
    ELSIF p_role_category IN ('retention_reception','retention_support') AND v_name = 'cautiousness' AND v_eff > 80 THEN
      v_eff := 80 - (v_eff - 80) * 0.5;
    END IF;

    v_detail := v_detail || jsonb_build_object(v_name, jsonb_build_object(
      'value', v_value, 'effective', v_eff, 'weight', v_weight, 'basis', v_citation));

    v_weighted_sum := v_weighted_sum + v_weight * v_eff;
    IF v_weight > 0 THEN
      v_denom := v_denom + v_weight;
    END IF;
  END LOOP;

  IF v_denom = 0 THEN
    v_fit := NULL;
  ELSE
    v_fit := GREATEST(0, LEAST(100, v_weighted_sum / v_denom));
  END IF;

  RETURN jsonb_build_object(
    'role_category', p_role_category,
    'fit_score', ROUND(v_fit, 1),
    'inputs', v_detail,
    'missing_inputs', to_jsonb(v_missing)
  );
END;
$function$;

COMMENT ON FUNCTION public._newtworks_role_fit_core(hiring_candidates, text) IS
'model_tag: role_fit_v5_0_facet_direct_2026_08_06 -- facet-direct role-fit core, replaces 13-competency composite pipeline. See in-body docstring for full design grounding and GMA/SJT input handling.';

CREATE OR REPLACE FUNCTION public._newtworks_role_fit_gated_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_fit jsonb;
  v_integrity_gate jsonb;
  v_reasoning_gate jsonb;
  v_gates_fired text[] := ARRAY[]::text[];
  v_verdict_cap text := NULL;
  v_hard_decline boolean := false;
  v_gma_pct numeric;
  v_ideal_min numeric;
  v_ideal_max numeric;
  v_mult numeric := 1.0;
BEGIN
  v_fit := public._newtworks_role_fit_core(p_candidate, p_role_category);

  IF v_fit ? 'error' THEN
    RETURN v_fit;
  END IF;

  -- GMA band gate (role_fit_v5_0_facet_direct_2026_08_06): replaces retired
  -- critical-floor loop. Reads gma from the core's OWN computed inputs
  -- (never recomputed here) so the gate and the weighted input can never
  -- disagree. If gma landed in missing_inputs, the gate is skipped entirely
  -- -- no multiplier, nothing appended to gates_fired.
  v_gma_pct := (v_fit -> 'inputs' -> 'gma' ->> 'value')::numeric;

  IF v_gma_pct IS NOT NULL THEN
    SELECT intelligence_ideal_min, intelligence_ideal_max INTO v_ideal_min, v_ideal_max
      FROM public.hiregauge_role_ideal_ranges
      WHERE agency_id = p_candidate.agency_id AND role_category = p_role_category;

    IF v_ideal_min IS NOT NULL AND v_ideal_max IS NOT NULL THEN
      v_mult := public.hiregauge_lss_penalty_v2(v_gma_pct, v_ideal_min)
              * public.hiregauge_lss_ceiling_penalty_v2(v_gma_pct, v_ideal_max);

      v_fit := jsonb_set(v_fit, '{fit_score}',
        to_jsonb(CASE WHEN (v_fit->>'fit_score') IS NULL THEN NULL
                      ELSE ROUND(((v_fit->>'fit_score')::numeric) * v_mult, 1) END));

      IF v_mult < 1.0 THEN
        v_gates_fired := array_append(v_gates_fired, 'gma_band');
      END IF;
    END IF;
  END IF;

  -- Gate (a): shadow mode. See _newtworks_integrity_decline_gate docstring.
  v_integrity_gate := public._newtworks_integrity_decline_gate(p_candidate);
  IF (v_integrity_gate->>'live_soft_flag')::boolean THEN
    v_gates_fired := array_append(v_gates_fired, 'integrity_flag');
    v_verdict_cap := 'consider';
  END IF;

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
      'gma_band', jsonb_build_object(
        'gma_percentile', v_gma_pct, 'ideal_min', v_ideal_min, 'ideal_max', v_ideal_max, 'multiplier', v_mult),
      'integrity_decline', v_integrity_gate,
      'reasoning', v_reasoning_gate
    )
  );
END;
$function$;
