-- Step 8 of HireGauge function architecture refactor
-- ==========================================================================
-- Purpose:
--   (a) Remove `leadership_style` from `additional_conditions` on 6 archetype
--       rules in `hiregauge_rules`. The `leadership_style` column on
--       `hiring_candidates` is being retired (Step 10) as a vestigial derived
--       label with no active enforcement value.
--   (b) Rewrite `hiregauge_evaluate_candidate` to strip its leadership_style
--       equality branch — otherwise the function would carry a dangling
--       reference to `v_assessment.leadership_style` after Step 10 drops the
--       column.
-- ==========================================================================

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(trait_signature, '{additional_conditions}',
    (trait_signature->'additional_conditions') - 'leadership_style')
WHERE id = '1bf19aa0-7df4-47da-aabe-8814ef7d36d3';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(trait_signature, '{additional_conditions}',
    (trait_signature->'additional_conditions') - 'leadership_style')
WHERE id = 'bc84714d-471e-4332-b430-7537553095c8';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(trait_signature, '{additional_conditions}',
    (trait_signature->'additional_conditions') - 'leadership_style')
WHERE id = '280b8593-b434-4998-ace6-cab7f8cc7034';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(trait_signature, '{additional_conditions}',
    (trait_signature->'additional_conditions') - 'leadership_style')
WHERE id = '7eb85168-ef23-4ad8-a025-ea18324eea18';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(trait_signature, '{additional_conditions}',
    (trait_signature->'additional_conditions') - 'leadership_style')
WHERE id = '2983402f-edec-4b8f-8e3b-76f7928ee0bd';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(trait_signature, '{additional_conditions}',
    (trait_signature->'additional_conditions') - 'leadership_style')
WHERE id = '5978dfa7-d03f-499a-888d-b70a591980b3';

CREATE OR REPLACE FUNCTION public.hiregauge_evaluate_candidate(p_assessment_id uuid)
 RETURNS TABLE(out_rule_id uuid, out_rule_type text, out_rule_name text, out_short_label text, out_match_confidence text, out_pass boolean, out_description text, out_recommendation text, out_diagnostic_action text, out_interview_probe text, out_coaching_prescription text, out_calibration_status text, out_n_count integer, out_hiring_stage text[])
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_assessment  public.hiring_candidates;
  v_rule        RECORD;
  v_condition   JSONB;
  v_all_pass    BOOLEAN;
  v_any_pass    BOOLEAN;
  v_condition_pass BOOLEAN;
  v_addl_pass   BOOLEAN;
  v_trait       TEXT;
  v_trait_value NUMERIC;
  v_op          TEXT;
  v_value       NUMERIC;
  v_value2      NUMERIC;
  v_threshold   NUMERIC;
  v_logic       TEXT;
  v_conditions_count INT;
  v_ceiling_count    INT;
  v_group_element    TEXT;
  v_ceiling_default  CONSTANT NUMERIC := 85;
  v_engine_floor     CONSTANT NUMERIC := 40;
  v_matched          BOOLEAN;
BEGIN
  SELECT * INTO v_assessment FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment not found: %', p_assessment_id;
  END IF;

  FOR v_rule IN
    SELECT
      r.id AS rid, r.rule_type AS rt, r.rule_name AS rn, r.short_label AS sl,
      r.trait_signature AS ts, r.description AS desc_txt, r.recommendation AS rec,
      r.diagnostic_action AS diag, r.interview_probe AS probe, r.coaching_prescription AS coach,
      r.calibration_status AS cs, r.n_count AS nc, r.hiring_stage AS hs
    FROM public.hiregauge_rules r
    WHERE r.is_active = true
      AND r.agency_id = v_assessment.agency_id
      AND r.trait_signature IS NOT NULL
    ORDER BY
      CASE r.calibration_status
        WHEN 'framework_principle' THEN 1
        WHEN 'calibrated_n3plus'   THEN 2
        WHEN 'watched_n2'          THEN 3
        WHEN 'emerging_n1'         THEN 4
        ELSE 5
      END,
      r.rule_type
  LOOP
    v_logic := COALESCE(v_rule.ts->>'logic', 'all');
    v_all_pass := true;
    v_any_pass := false;
    v_conditions_count := 0;
    v_addl_pass := true;

    IF v_rule.ts ? 'trait_conditions' THEN
      FOR v_condition IN SELECT * FROM jsonb_array_elements(v_rule.ts->'trait_conditions')
      LOOP
        v_conditions_count := v_conditions_count + 1;
        v_condition_pass := false;
        v_op    := v_condition->>'op';
        v_trait := v_condition->>'trait';

        IF v_trait = 'reliability' THEN
          IF v_op = 'eq' THEN
            v_condition_pass := (v_assessment.reliability = v_condition->>'value');
          ELSIF v_op = 'in' AND v_condition ? 'values' THEN
            v_condition_pass := v_assessment.reliability = ANY(
              ARRAY(SELECT jsonb_array_elements_text(v_condition->'values'))
            );
          END IF;

        ELSIF v_trait = 'response_distortion' THEN
          IF v_op = 'eq' THEN
            v_condition_pass := (v_assessment.response_distortion = v_condition->>'value');
          END IF;

        ELSIF v_trait = 'multi_ceiling' AND v_op = 'count_gte'
              AND v_condition ? 'group' AND v_condition ? 'value' THEN
          v_threshold := COALESCE((v_condition->>'threshold')::numeric, v_ceiling_default);
          v_ceiling_count := 0;
          FOR v_group_element IN SELECT jsonb_array_elements_text(v_condition->'group')
          LOOP
            IF COALESCE(public._hiregauge_get_trait_value(v_assessment, v_group_element), -1) >= v_threshold THEN
              v_ceiling_count := v_ceiling_count + 1;
            END IF;
          END LOOP;
          v_condition_pass := v_ceiling_count >= (v_condition->>'value')::int;

        ELSIF v_trait = 'ceiling_count' AND v_op = 'gte'
              AND v_condition ? 'traits' AND v_condition ? 'value' THEN
          v_threshold := COALESCE((v_condition->>'threshold')::numeric, v_ceiling_default);
          v_ceiling_count := 0;
          FOR v_group_element IN SELECT jsonb_array_elements_text(v_condition->'traits')
          LOOP
            IF COALESCE(public._hiregauge_get_trait_value(v_assessment, v_group_element), -1) >= v_threshold THEN
              v_ceiling_count := v_ceiling_count + 1;
            END IF;
          END LOOP;
          v_condition_pass := v_ceiling_count >= (v_condition->>'value')::int;

        ELSIF v_trait = 'any_drive_trait' AND v_op = 'gte'
              AND v_condition ? 'traits' AND v_condition ? 'value' THEN
          v_value := (v_condition->>'value')::numeric;
          v_condition_pass := false;
          FOR v_group_element IN SELECT jsonb_array_elements_text(v_condition->'traits')
          LOOP
            IF COALESCE(public._hiregauge_get_trait_value(v_assessment, v_group_element), -1) >= v_value THEN
              v_condition_pass := true;
              EXIT;
            END IF;
          END LOOP;

        ELSE
          v_trait_value := public._hiregauge_get_trait_value(v_assessment, v_trait);
          IF v_trait_value IS NOT NULL AND v_condition ? 'value' THEN
            v_value := (v_condition->>'value')::numeric;
            CASE v_op
              WHEN 'gte' THEN v_condition_pass := v_trait_value >= v_value;
              WHEN 'lte' THEN v_condition_pass := v_trait_value <= v_value;
              WHEN 'lt'  THEN v_condition_pass := v_trait_value <  v_value;
              WHEN 'gt'  THEN v_condition_pass := v_trait_value >  v_value;
              WHEN 'eq'  THEN v_condition_pass := v_trait_value =  v_value;
              WHEN 'between' THEN
                IF v_condition ? 'value2' THEN
                  v_value2 := (v_condition->>'value2')::numeric;
                  v_condition_pass := v_trait_value BETWEEN v_value AND v_value2;
                END IF;
              ELSE v_condition_pass := false;
            END CASE;
          END IF;
        END IF;

        IF v_condition_pass THEN v_any_pass := true;
        ELSE                     v_all_pass := false;
        END IF;
      END LOOP;
    ELSE
      v_conditions_count := 0;
      v_all_pass := false;
    END IF;

    -- Note: leadership_style equality branch removed 2026-07-23 (Step 8).
    IF v_rule.ts ? 'additional_conditions' THEN
      IF v_rule.ts->'additional_conditions' ? 'engine_floors_present'
         AND (v_rule.ts->'additional_conditions'->>'engine_floors_present')::boolean = true THEN
        IF NOT (
          COALESCE(v_assessment.deadline_motivation, 999) <= v_engine_floor OR
          COALESCE(v_assessment.recognition_drive,   999) <= v_engine_floor OR
          COALESCE(v_assessment.assertiveness,       999) <= v_engine_floor
        ) THEN
          v_addl_pass := false;
        END IF;
      END IF;

      IF v_rule.ts->'additional_conditions' ? 'has_drive_trait_gte_55'
         AND (v_rule.ts->'additional_conditions'->>'has_drive_trait_gte_55')::boolean = true THEN
        IF NOT (
          COALESCE(v_assessment.deadline_motivation, 0) >= 55 OR
          COALESCE(v_assessment.recognition_drive,   0) >= 55 OR
          COALESCE(v_assessment.assertiveness,       0) >= 55
        ) THEN
          v_addl_pass := false;
        END IF;
      END IF;

      IF v_rule.ts->'additional_conditions' ? 'two_of_ceilings' THEN
        v_ceiling_count := 0;
        FOR v_group_element IN SELECT jsonb_array_elements_text(v_rule.ts->'additional_conditions'->'two_of_ceilings')
        LOOP
          IF COALESCE(public._hiregauge_get_trait_value(v_assessment, v_group_element), -1) >= v_ceiling_default THEN
            v_ceiling_count := v_ceiling_count + 1;
          END IF;
        END LOOP;
        IF v_ceiling_count < 2 THEN v_addl_pass := false; END IF;
      END IF;
    END IF;

    v_matched := v_conditions_count > 0
                 AND ((v_logic = 'all' AND v_all_pass) OR (v_logic = 'any' AND v_any_pass))
                 AND v_addl_pass;

    IF v_matched THEN
      out_rule_id := v_rule.rid;
      out_rule_type := v_rule.rt;
      out_rule_name := v_rule.rn;
      out_short_label := v_rule.sl;
      out_match_confidence := 'full_match';
      out_pass := true;
      out_description := v_rule.desc_txt;
      out_recommendation := v_rule.rec;
      out_diagnostic_action := v_rule.diag;
      out_interview_probe := v_rule.probe;
      out_coaching_prescription := v_rule.coach;
      out_calibration_status := v_rule.cs;
      out_n_count := v_rule.nc;
      out_hiring_stage := v_rule.hs;
      RETURN NEXT;
    ELSIF v_rule.rt = 'character_floor' AND v_conditions_count > 0 THEN
      out_rule_id := v_rule.rid;
      out_rule_type := v_rule.rt;
      out_rule_name := v_rule.rn;
      out_short_label := v_rule.sl;
      out_match_confidence := 'floor_failed';
      out_pass := false;
      out_description := v_rule.desc_txt;
      out_recommendation := v_rule.rec;
      out_diagnostic_action := v_rule.diag;
      out_interview_probe := v_rule.probe;
      out_coaching_prescription := v_rule.coach;
      out_calibration_status := v_rule.cs;
      out_n_count := v_rule.nc;
      out_hiring_stage := v_rule.hs;
      RETURN NEXT;
    END IF;
  END LOOP;

  RETURN;
END;
$function$;
