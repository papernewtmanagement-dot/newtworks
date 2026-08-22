-- Peter directive 2026-08-04: move enterprising out of the three personality
-- competencies. Enterprising is a vocational INTEREST (Holland RIASEC via O*NET),
-- a separate construct domain from personality: interest-job congruence predicts
-- on its own track (Nye, Su, Rounds & Drasgow 2012, PPS 7(4), rho ~.20; Van
-- Iddekinge, Roth, Putka & Lanivich 2011, JAP 96(6)). It now feeds the Commitment
-- construct (assessment_commitment new path, migration 20260805003202). Leaving it
-- inside personality competencies (a) contaminates personality composites with an
-- interest measure and (b) double-counts the same score in the verdict now that
-- Commitment reads it. Zero new-instrument candidates exist, so no issued scores
-- change. Bodies are byte-identical to the live definitions except the enterprising
-- array entries are removed (composites renormalize automatically over remaining
-- inputs; unit weights per Wainer 1976 / Ree et al. 1994 unchanged).

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
          (v_norm->>'proactive_personality')::numeric],
    ARRAY['achievement_striving','self_discipline','proactive_personality'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'drive_work_intensity');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'drive_work_intensity');
END; $function$;

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
          (v_norm->>'self_efficacy')::numeric],
    ARRAY['assertiveness','political_skill_networking','self_efficacy'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'persuasive_influence');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'persuasive_influence');
END; $function$;

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
          (v_norm->>'achievement_striving')::numeric],
    ARRAY['proactive_personality','self_efficacy','achievement_striving'],
    p_candidate.reliability, p_candidate.response_distortion);
  IF p_role_category IS NOT NULL THEN
    v_ctx := public._newtworks_competency_role_context(p_candidate.agency_id, p_role_category, 'autonomy_ownership');
  END IF;
  RETURN v_core || v_ctx || jsonb_build_object('competency', 'autonomy_ownership');
END; $function$;
