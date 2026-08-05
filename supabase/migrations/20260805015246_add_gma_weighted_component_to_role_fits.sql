-- Peter directive 2026-08-04: "I want whatever the research says. If it supports
-- it, add GMA weight." It does. Prior ruling (*Ass Comp Plan, 2026-08-02) demoted
-- GMA from a MULTIPLIER on other scores because the multiplicative
-- ability-x-motivation form fails empirically (Van Iddekinge, Aguinis, Mackey &
-- DeOrtentiis 2018; Coward & Sackett 1990 linearity; Brown, Wai & Chabris 2021 no
-- threshold). That ruling endorses ADDITIVE GMA, which is exactly this change.
-- Before: GMA carried only ~4-6% effective weight (via 3 competencies at 1/4 each)
-- plus a pass/fail gate. Sackett, Zhang, Berry & Lievens 2022 (JAP 107(11)) keeps
-- cognitive ability among the top predictors even after correcting the classic
-- overestimates, and validity scales with job complexity (Hunter & Hunter 1984 --
-- the same complexity gradient the role_ideal_ranges rows are built on). For
-- commission sales seats, Vinchur et al. 1998 (GMA r=.04 with OBJECTIVE sales)
-- argues supportive-not-dominant weight; licensing/training success (a GMA
-- strength, and Suggs dimension 5 in core_principles Recruiting) keeps sales
-- seats at 'important' rather than 'supporting'.
-- Tiering: aspirant 3 (professional-managerial destination role), sales_* and
-- retention_escalation 2, retention_reception and retention_support 1.
-- Resulting total GMA influence: ~15% aspirant, ~11-12% sales, ~7-9% reception/
-- support -- additive, linear, no multiplier, consistent with all prior rulings.
-- Zero new-instrument candidates exist, so no issued scores change.

CREATE OR REPLACE FUNCTION public.newtworks_competency_gma(p_candidate hiring_candidates, p_role_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_norm jsonb; v_core jsonb; v_ctx jsonb := '{}'::jsonb;
BEGIN
  v_norm := public.hiregauge_v2_normalized_inputs(p_candidate.id);
  v_core := public._newtworks_competency_composite(
    ARRAY[(v_norm->>'gma_total')::numeric],
    ARRAY['gma_total'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'gma');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'gma');
END; $function$;

CREATE OR REPLACE FUNCTION public._newtworks_role_fit_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_names text[] := ARRAY['drive_work_intensity','persuasive_influence','rapport_building',
    'needs_discovery','resilience_under_rejection','composure_under_pressure',
    'accuracy_procedural_discipline','rule_compliance_adherence','integrity',
    'judgment_escalation','coachability_team_contribution','autonomy_ownership','gma'];
  v_name text;
  v_comp jsonb;
  v_weight numeric;
  v_weighted_sum numeric := 0;
  v_weight_total numeric := 0;
  v_detail jsonb := '{}'::jsonb;
  v_missing text[] := ARRAY[]::text[];
  v_fit numeric;
BEGIN
  IF p_candidate.achievement_striving IS NULL THEN
    RETURN jsonb_build_object('error', 'no_trait_data', 'role_category', p_role_category);
  END IF;

  FOREACH v_name IN ARRAY v_names LOOP
    v_comp := CASE v_name
      WHEN 'drive_work_intensity' THEN public.newtworks_competency_drive_work_intensity(p_candidate, p_role_category)
      WHEN 'persuasive_influence' THEN public.newtworks_competency_persuasive_influence(p_candidate, p_role_category)
      WHEN 'rapport_building' THEN public.newtworks_competency_rapport_building(p_candidate, p_role_category)
      WHEN 'needs_discovery' THEN public.newtworks_competency_needs_discovery(p_candidate, p_role_category)
      WHEN 'resilience_under_rejection' THEN public.newtworks_competency_resilience_under_rejection(p_candidate, p_role_category)
      WHEN 'composure_under_pressure' THEN public.newtworks_competency_composure_under_pressure(p_candidate, p_role_category)
      WHEN 'accuracy_procedural_discipline' THEN public.newtworks_competency_accuracy_procedural_discipline(p_candidate, p_role_category)
      WHEN 'rule_compliance_adherence' THEN public.newtworks_competency_rule_compliance_adherence(p_candidate, p_role_category)
      WHEN 'integrity' THEN public.newtworks_competency_integrity(p_candidate, p_role_category)
      WHEN 'judgment_escalation' THEN public.newtworks_competency_judgment_escalation(p_candidate, p_role_category)
      WHEN 'coachability_team_contribution' THEN public.newtworks_competency_coachability_team_contribution(p_candidate, p_role_category)
      WHEN 'autonomy_ownership' THEN public.newtworks_competency_autonomy_ownership(p_candidate, p_role_category)
      WHEN 'gma' THEN public.newtworks_competency_gma(p_candidate, p_role_category)
    END;

    v_detail := v_detail || jsonb_build_object(v_name, v_comp);

    IF (v_comp->>'adjusted') IS NULL THEN
      v_missing := array_append(v_missing, v_name);
      CONTINUE;
    END IF;

    SELECT weight INTO v_weight FROM public.hiregauge_competency_weights
      WHERE agency_id = p_candidate.agency_id AND role_category = p_role_category AND competency_name = v_name;
    v_weight := COALESCE(v_weight, 1);

    v_weighted_sum := v_weighted_sum + (v_comp->>'adjusted')::numeric * v_weight;
    v_weight_total := v_weight_total + v_weight;
  END LOOP;

  IF v_weight_total = 0 THEN
    v_fit := NULL;
  ELSE
    v_fit := ROUND(v_weighted_sum / v_weight_total, 1);
  END IF;

  RETURN jsonb_build_object(
    'role_category', p_role_category,
    'fit_score', v_fit,
    'competencies', v_detail,
    'missing_competencies', v_missing
  );
END;
$function$;

INSERT INTO public.hiregauge_competency_weights (agency_id, role_category, competency_name, weight, tier)
SELECT '126794dd-25ff-47d2-a436-724499733365', r.role_category, 'gma', r.weight, r.tier
FROM (VALUES
  ('aspirant',             3, 'critical'),
  ('sales_outbound',       2, 'important'),
  ('sales_inbound',        2, 'important'),
  ('sales_in_book',        2, 'important'),
  ('retention_escalation', 2, 'important'),
  ('retention_reception',  1, 'supporting'),
  ('retention_support',    1, 'supporting')
) AS r(role_category, weight, tier)
WHERE NOT EXISTS (
  SELECT 1 FROM public.hiregauge_competency_weights w
  WHERE w.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND w.role_category = r.role_category
    AND w.competency_name = 'gma'
);
