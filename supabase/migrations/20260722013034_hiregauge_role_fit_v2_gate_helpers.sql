-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-22 01:30:34 UTC (ledger name: hiregauge_role_fit_v2_gate_helpers) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260722013034.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE FUNCTION public._cts_role_fit_gates_v2(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  SELECT jsonb_build_object(
    'validity_dampen',   (reliability IN ('low','questionable') OR response_distortion IN ('moderate','elevated','high')),
    'shadow_read',       (
      independent_spirit < 15 AND
      ((CASE WHEN self_promotion >= 85 THEN 1 ELSE 0 END)
       + (CASE WHEN analytical >= 85 THEN 1 ELSE 0 END)
       + (CASE WHEN compassion >= 85 THEN 1 ELSE 0 END)
       + (CASE WHEN belief_in_others >= 85 THEN 1 ELSE 0 END)
       + (CASE WHEN optimism >= 85 THEN 1 ELSE 0 END)) >= 2
    ),
    'hollow_broadcast',  (optimism >= 85 AND compassion < 30),
    'coo_fail',          (compassion < 30),
    'hwe_fail',          (deadline_motivation < 30 AND independent_spirit < 30),
    'pit_deficit',       (optimism < 30),
    'deadline_motivation', deadline_motivation,
    'reliability',       reliability,
    'distortion',        response_distortion
  )
  FROM public.hiring_candidates
  WHERE id = p_assessment_id;
$function$;

CREATE OR REPLACE FUNCTION public._cts_role_fit_apply_gates_v2(
  p_assessment_id uuid,
  p_role text,
  p_raw_score numeric,
  p_floor_comp_cap numeric,
  p_floor_source text,
  p_floor_source_val numeric
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  gates jsonb;
  v_dampened numeric;
  v_after_comp_cap numeric;
  v_final numeric;
  v_adjustments jsonb := '[]'::jsonb;
  v_coo_cap numeric;
  v_hwe_cap numeric;
  v_pit_cap numeric;
  v_deadline_cap numeric := 999;
BEGIN
  gates := public._cts_role_fit_gates_v2(p_assessment_id);
  v_dampened := p_raw_score;

  IF (gates->>'validity_dampen')::boolean THEN
    v_dampened := v_dampened * 0.85;
    v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
      'kind','validity_dampener','factor',0.85,
      'reliability', gates->>'reliability', 'distortion', gates->>'distortion'
    ));
  END IF;

  IF (gates->>'shadow_read')::boolean THEN
    v_dampened := v_dampened * 0.75;
    v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
      'kind','shadow_read','factor',0.75,
      'reason','IS floor with 2+ ceilings on SP/AN/CO/BO/OP'
    ));
  END IF;

  IF (gates->>'hollow_broadcast')::boolean THEN
    v_dampened := v_dampened * 0.80;
    v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
      'kind','hollow_broadcast','factor',0.80,
      'reason','Optimism ceiling + Compassion floor'
    ));
  END IF;

  v_after_comp_cap := LEAST(v_dampened, p_floor_comp_cap);

  IF p_role = 'sales_outbound' THEN
    v_coo_cap := 55; v_hwe_cap := 50; v_pit_cap := 55;
  ELSIF p_role = 'sales_inbound' THEN
    v_coo_cap := 45; v_hwe_cap := 50; v_pit_cap := 55;
  ELSIF p_role = 'sales_in_book' THEN
    v_coo_cap := 45; v_hwe_cap := 50; v_pit_cap := 55;
  ELSIF p_role = 'aspirant' THEN
    v_coo_cap := 45; v_hwe_cap := 50; v_pit_cap := 55;
    v_deadline_cap := (gates->>'deadline_motivation')::numeric + 15;
  ELSIF p_role = 'retention_reception' THEN
    v_coo_cap := 45; v_hwe_cap := 55; v_pit_cap := 55;
  ELSIF p_role = 'retention_escalation' THEN
    v_coo_cap := 45; v_hwe_cap := 55; v_pit_cap := 55;
  ELSIF p_role = 'retention_support' THEN
    v_coo_cap := 100; v_hwe_cap := 60; v_pit_cap := 100;
  ELSE
    v_coo_cap := 100; v_hwe_cap := 100; v_pit_cap := 100;
  END IF;

  v_final := v_after_comp_cap;

  IF (gates->>'coo_fail')::boolean AND v_coo_cap < 100 THEN
    IF v_coo_cap < v_final THEN
      v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
        'kind','concern_for_others_cap','cap',v_coo_cap,'reason','raw Compassion < 30'
      ));
      v_final := v_coo_cap;
    END IF;
  END IF;

  IF (gates->>'hwe_fail')::boolean THEN
    IF v_hwe_cap < v_final THEN
      v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
        'kind','hwe_fail_cap','cap',v_hwe_cap,'reason','raw DM < 30 AND raw IS < 30'
      ));
      v_final := v_hwe_cap;
    END IF;
  END IF;

  IF (gates->>'pit_deficit')::boolean AND v_pit_cap < 100 THEN
    IF v_pit_cap < v_final THEN
      v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
        'kind','pit_deficit_cap','cap',v_pit_cap,'reason','raw Optimism < 30 (PIT poison risk)'
      ));
      v_final := v_pit_cap;
    END IF;
  END IF;

  IF p_role = 'aspirant' AND v_deadline_cap < v_final THEN
    v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
      'kind','aspirant_deadline_cap','cap',v_deadline_cap,
      'deadline_motivation',(gates->>'deadline_motivation')::numeric,
      'reason','owner-track drive requires sustained Deadline'
    ));
    v_final := v_deadline_cap;
  END IF;

  RETURN jsonb_build_object(
    'fit_score', GREATEST(0, LEAST(100, ROUND(v_final)))::int,
    'raw_score', ROUND(p_raw_score, 2),
    'dampened_score', ROUND(v_dampened, 2),
    'after_comp_cap', ROUND(v_after_comp_cap, 2),
    'floor_comp_cap', ROUND(p_floor_comp_cap, 2),
    'floor_source', p_floor_source,
    'floor_source_value', p_floor_source_val,
    'adjustments', v_adjustments,
    'gates', gates
  );
END;
$function$;
