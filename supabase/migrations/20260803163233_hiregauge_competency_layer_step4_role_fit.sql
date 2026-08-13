-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-03 16:32:33 UTC (ledger name: hiregauge_competency_layer_step4_role_fit) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260803163233.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Step 4 of the 12-competency rebuild: 7 role_fit functions.
-- Weighted mean of the 12 competencies per hiregauge_competency_weights
-- (critical=3, important=2, supporting=1). Reasoning enters only through
-- competencies 4/7/10 (already baked into their own composites) -- no
-- separate multiplier, no global ability term. Entry guard checks trait
-- columns are populated, not the retired deadline_motivation column.

CREATE OR REPLACE FUNCTION public._newtworks_role_fit_core(p_candidate hiring_candidates, p_role_category text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_names text[] := ARRAY['drive_work_intensity','persuasive_influence','rapport_building',
    'needs_discovery','resilience_under_rejection','composure_under_pressure',
    'accuracy_procedural_discipline','rule_compliance_adherence','integrity',
    'judgment_escalation','coachability_team_contribution','autonomy_ownership'];
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
$fn$;

COMMENT ON FUNCTION public._newtworks_role_fit_core(hiring_candidates, text) IS
'Shared core for all 7 newtworks_role_fit_* functions. Weighted mean of the
12 competencies'' adjusted scores using hiregauge_competency_weights
(critical=3/important=2/supporting=1). Reasoning enters only through
competencies 4 (needs_discovery), 7 (accuracy_procedural_discipline), 10
(judgment_escalation) -- already folded into their own composites, no
separate multiplier applied here (Van Iddekinge et al. 2018). Entry guard
checks achievement_striving (proxy for the full 21-trait personality block
being populated) rather than the retired deadline_motivation column.';

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_sales_outbound(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_core(p_candidate, 'sales_outbound'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_sales_inbound(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_core(p_candidate, 'sales_inbound'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_sales_in_book(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_core(p_candidate, 'sales_in_book'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_retention_escalation(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_core(p_candidate, 'retention_escalation'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_retention_reception(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_core(p_candidate, 'retention_reception'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_retention_support(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_core(p_candidate, 'retention_support'); $fn$;

CREATE OR REPLACE FUNCTION public.newtworks_role_fit_aspirant(p_candidate hiring_candidates) RETURNS jsonb
LANGUAGE sql STABLE AS $fn$ SELECT public._newtworks_role_fit_core(p_candidate, 'aspirant'); $fn$;
