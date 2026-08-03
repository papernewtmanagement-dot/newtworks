-- Step 3 of the 12-competency rebuild (op-rule "Newtworks competency layer —
-- 12-competency library + role matrix (confirmed 2026-08-02)").
-- Consumes hiregauge_v2_normalized_inputs(candidate_id) (Step 2, already
-- shipped) as the single normalized-input source.

-- BUG FIX (same class as the earlier GMA FACET_COLUMNS dead-name bug):
-- _assessment_dampen_trait_by_distortion checked p_trait_name against the
-- literal string 'optimism', but the live v2 trait column is
-- 'dispositional_optimism' -- the string never matched, so dampening
-- silently never fired for that trait. 'belief_in_others' and
-- 'self_promotion' are retired vendor construct names with no v2
-- equivalent; left in the CASE for harmless backward compatibility with any
-- caller still passing those (none currently do).
CREATE OR REPLACE FUNCTION public._assessment_dampen_trait_by_distortion(p_trait integer, p_trait_name text, p_distortion text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_trait IS NULL THEN NULL
    WHEN p_trait_name NOT IN ('compassion', 'dispositional_optimism', 'optimism', 'belief_in_others', 'self_promotion') THEN p_trait
    WHEN p_trait <= 65 THEN p_trait
    ELSE GREATEST(65, p_trait - (10 * public._assessment_distortion_severity(p_distortion))::int)
  END;
$function$;

-- Core scoring engine. Unit-weighted mean of normalized inputs -> base.
-- Distortion-dampen socially-desirable trait inputs (compassion,
-- dispositional_optimism only -- the only two of the 21 active traits the
-- dampen helper recognizes) -> re-average -> adjusted_base. Reliability
-- shrinks adjusted_base toward 50 (regression toward the mean for
-- less-reliable response patterns, not a flat penalty) -> adjusted.
-- NULL-safe: 2+ missing inputs -> base/adjusted both NULL, not a partial
-- average (per the 12-competency op-rule and the 0-100 universal rule).
CREATE OR REPLACE FUNCTION public._newtworks_competency_composite(p_values numeric[], p_labels text[], p_reliability text, p_distortion text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_n int := COALESCE(array_length(p_values,1), 0);
  v_missing int := 0;
  v_base numeric;
  v_adjusted_base numeric;
  v_adjusted numeric;
  v_reliability_mult numeric;
  v_inputs_used text[] := ARRAY[]::text[];
  v_missing_inputs text[] := ARRAY[]::text[];
  v_dampened numeric[] := ARRAY[]::numeric[];
  i int;
BEGIN
  IF v_n = 0 THEN
    RETURN jsonb_build_object('base', NULL, 'adjusted', NULL,
      'inputs_used', v_inputs_used, 'missing_inputs', v_missing_inputs,
      'reason', 'no_inputs_configured');
  END IF;

  FOR i IN 1..v_n LOOP
    IF p_values[i] IS NULL THEN
      v_missing := v_missing + 1;
      v_missing_inputs := array_append(v_missing_inputs, p_labels[i]);
    ELSE
      v_inputs_used := array_append(v_inputs_used, p_labels[i]);
    END IF;
  END LOOP;

  IF v_missing > 1 THEN
    RETURN jsonb_build_object('base', NULL, 'adjusted', NULL,
      'inputs_used', v_inputs_used, 'missing_inputs', v_missing_inputs,
      'reason', 'more_than_one_input_missing');
  END IF;

  SELECT ROUND(AVG(v),1) INTO v_base FROM unnest(p_values) AS v WHERE v IS NOT NULL;

  FOR i IN 1..v_n LOOP
    IF p_values[i] IS NULL THEN
      v_dampened := array_append(v_dampened, NULL::numeric);
    ELSIF p_labels[i] IN ('compassion','dispositional_optimism') THEN
      v_dampened := array_append(v_dampened,
        public._assessment_dampen_trait_by_distortion(p_values[i]::int, p_labels[i], p_distortion)::numeric);
    ELSE
      v_dampened := array_append(v_dampened, p_values[i]);
    END IF;
  END LOOP;

  SELECT ROUND(AVG(v),1) INTO v_adjusted_base FROM unnest(v_dampened) AS v WHERE v IS NOT NULL;
  v_reliability_mult := public._assessment_reliability_confidence(p_reliability);
  v_adjusted := ROUND(50 + (v_adjusted_base - 50) * v_reliability_mult, 1);

  RETURN jsonb_build_object(
    'base', v_base, 'adjusted', v_adjusted,
    'inputs_used', v_inputs_used, 'missing_inputs', v_missing_inputs
  );
END;
$function$;

COMMENT ON FUNCTION public._newtworks_competency_composite(numeric[], text[], text, text) IS
'Shared scoring core for all 12 newtworks_competency_* functions. Unit-
weighted mean per Wainer 1976 / Ree, Earles & Teachout 1994 (simple
composites match complex-weighted ones in predictive validity -- simple
happens to be accurate here, not a shortcut). base excludes data-quality
adjustments; adjusted applies distortion dampening + reliability shrink
toward 50. NULL-safe per the 12-competency op-rule: >1 missing input
returns NULL/NULL, never a partial average presented as real.';

-- Wrapper helper: builds the floor/tier lookup shared by all 12 functions.
CREATE OR REPLACE FUNCTION public._newtworks_competency_role_context(p_agency_id uuid, p_role_category text, p_competency_name text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  SELECT jsonb_build_object(
    'floor', (SELECT floor FROM public.hiregauge_competency_floors
              WHERE agency_id = p_agency_id AND role_category = p_role_category
                AND competency_name = p_competency_name),
    'tier', (SELECT tier FROM public.hiregauge_competency_weights
             WHERE agency_id = p_agency_id AND role_category = p_role_category
               AND competency_name = p_competency_name)
  );
$function$;

-- 1. Drive & Work Intensity
CREATE OR REPLACE FUNCTION public.newtworks_competency_drive_work_intensity(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'achievement_striving')::numeric, (v_norm->>'self_discipline')::numeric,
          (v_norm->>'proactive_personality')::numeric, (v_norm->>'enterprising')::numeric],
    ARRAY['achievement_striving','self_discipline','proactive_personality','enterprising'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'drive_work_intensity');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'drive_work_intensity');
END; $function$;

-- 2. Persuasive Influence
CREATE OR REPLACE FUNCTION public.newtworks_competency_persuasive_influence(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'assertiveness')::numeric, (v_norm->>'political_skill_networking')::numeric,
          (v_norm->>'self_efficacy')::numeric, (v_norm->>'enterprising')::numeric],
    ARRAY['assertiveness','political_skill_networking','self_efficacy','enterprising'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'persuasive_influence');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'persuasive_influence');
END; $function$;

-- 3. Rapport Building
CREATE OR REPLACE FUNCTION public.newtworks_competency_rapport_building(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'friendliness')::numeric, (v_norm->>'political_skill_networking')::numeric,
          (v_norm->>'compassion')::numeric, (v_norm->>'trust')::numeric],
    ARRAY['friendliness','political_skill_networking','compassion','trust'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'rapport_building');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'rapport_building');
END; $function$;

-- 4. Needs Discovery & Listening (reasoning input #1 of 3)
CREATE OR REPLACE FUNCTION public.newtworks_competency_needs_discovery(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'customer_orientation')::numeric, (v_norm->>'compassion')::numeric,
          (v_norm->>'cooperation')::numeric, (v_norm->>'gma_total')::numeric],
    ARRAY['customer_orientation','compassion','cooperation','gma_total'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'needs_discovery');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'needs_discovery');
END; $function$;

-- 5. Resilience Under Rejection (anxiety reversed)
CREATE OR REPLACE FUNCTION public.newtworks_competency_resilience_under_rejection(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'emotional_stability')::numeric,
          CASE WHEN (v_norm->>'anxiety') IS NULL THEN NULL ELSE 100 - (v_norm->>'anxiety')::numeric END,
          (v_norm->>'dispositional_optimism')::numeric, (v_norm->>'self_efficacy')::numeric],
    ARRAY['emotional_stability','anxiety_reversed','dispositional_optimism','self_efficacy'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'resilience_under_rejection');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'resilience_under_rejection');
END; $function$;

-- 6. Composure Under Pressure (anger + anxiety reversed, scenario: composure)
CREATE OR REPLACE FUNCTION public.newtworks_competency_composure_under_pressure(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[CASE WHEN (v_norm->>'anger') IS NULL THEN NULL ELSE 100 - (v_norm->>'anger')::numeric END,
          CASE WHEN (v_norm->>'anxiety') IS NULL THEN NULL ELSE 100 - (v_norm->>'anxiety')::numeric END,
          (v_norm->>'emotional_stability')::numeric, (v_norm->>'sjt_composure_under_load')::numeric],
    ARRAY['anger_reversed','anxiety_reversed','emotional_stability','sjt_composure_under_load'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'composure_under_pressure');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'composure_under_pressure');
END; $function$;

-- 7. Accuracy & Procedural Discipline (reasoning input #2 of 3)
CREATE OR REPLACE FUNCTION public.newtworks_competency_accuracy_procedural_discipline(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'dutifulness')::numeric, (v_norm->>'cautiousness')::numeric,
          (v_norm->>'self_discipline')::numeric, (v_norm->>'gma_total')::numeric],
    ARRAY['dutifulness','cautiousness','self_discipline','gma_total'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'accuracy_procedural_discipline');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'accuracy_procedural_discipline');
END; $function$;

-- 8. Rule & Compliance Adherence (2 scenario topics)
CREATE OR REPLACE FUNCTION public.newtworks_competency_rule_compliance_adherence(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'dutifulness')::numeric, (v_norm->>'cautiousness')::numeric,
          (v_norm->>'sjt_compliance_licensing_boundary')::numeric, (v_norm->>'sjt_compliance_outbound_consent')::numeric],
    ARRAY['dutifulness','cautiousness','sjt_compliance_licensing_boundary','sjt_compliance_outbound_consent'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'rule_compliance_adherence');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'rule_compliance_adherence');
END; $function$;

-- 9. Integrity
CREATE OR REPLACE FUNCTION public.newtworks_competency_integrity(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'sincerity')::numeric, (v_norm->>'fairness')::numeric,
          (v_norm->>'greed_avoidance')::numeric, (v_norm->>'sjt_honesty_integrity')::numeric],
    ARRAY['sincerity','fairness','greed_avoidance','sjt_honesty_integrity'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'integrity');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'integrity');
END; $function$;

-- 10. Judgment & Escalation (reasoning input #3 of 3)
CREATE OR REPLACE FUNCTION public.newtworks_competency_judgment_escalation(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'sjt_escalation_judgment')::numeric, (v_norm->>'cautiousness')::numeric,
          (v_norm->>'dutifulness')::numeric, (v_norm->>'gma_total')::numeric],
    ARRAY['sjt_escalation_judgment','cautiousness','dutifulness','gma_total'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'judgment_escalation');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'judgment_escalation');
END; $function$;

-- 11. Coachability & Team Contribution (anger reversed)
CREATE OR REPLACE FUNCTION public.newtworks_competency_coachability_team_contribution(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'cooperation')::numeric, (v_norm->>'trust')::numeric,
          (v_norm->>'compassion')::numeric,
          CASE WHEN (v_norm->>'anger') IS NULL THEN NULL ELSE 100 - (v_norm->>'anger')::numeric END],
    ARRAY['cooperation','trust','compassion','anger_reversed'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'coachability_team_contribution');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'coachability_team_contribution');
END; $function$;

-- 12. Autonomy & Ownership
CREATE OR REPLACE FUNCTION public.newtworks_competency_autonomy_ownership(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'proactive_personality')::numeric, (v_norm->>'self_efficacy')::numeric,
          (v_norm->>'enterprising')::numeric, (v_norm->>'achievement_striving')::numeric],
    ARRAY['proactive_personality','self_efficacy','enterprising','achievement_striving'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'autonomy_ownership');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'autonomy_ownership');
END; $function$;
