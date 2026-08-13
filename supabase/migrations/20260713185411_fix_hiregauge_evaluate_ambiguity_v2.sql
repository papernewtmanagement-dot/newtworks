-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-13 18:54:11 UTC (ledger name: fix_hiregauge_evaluate_ambiguity_v2) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260713185411.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
DROP FUNCTION IF EXISTS public.hiregauge_evaluate_candidate(UUID);

CREATE FUNCTION public.hiregauge_evaluate_candidate(p_assessment_id UUID)
RETURNS TABLE (
  out_rule_id UUID,
  out_rule_type TEXT,
  out_rule_name TEXT,
  out_short_label TEXT,
  out_match_confidence TEXT,
  out_description TEXT,
  out_recommendation TEXT,
  out_diagnostic_action TEXT,
  out_interview_probe TEXT,
  out_coaching_prescription TEXT,
  out_calibration_status TEXT,
  out_n_count INT,
  out_hiring_stage TEXT[]
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_assessment RECORD;
  v_rule RECORD;
  v_condition JSONB;
  v_all_pass BOOLEAN;
  v_any_pass BOOLEAN;
  v_condition_pass BOOLEAN;
  v_trait_value NUMERIC;
  v_op TEXT;
  v_value NUMERIC;
  v_value2 NUMERIC;
  v_logic TEXT;
  v_conditions_count INT;
BEGIN
  SELECT * INTO v_assessment
  FROM public.team_assessments
  WHERE id = p_assessment_id;

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
        WHEN 'calibrated_n3plus' THEN 2
        WHEN 'watched_n2' THEN 3
        WHEN 'emerging_n1' THEN 4
        ELSE 5
      END,
      r.rule_type
  LOOP
    v_logic := COALESCE(v_rule.ts->>'logic', 'all');
    v_all_pass := true;
    v_any_pass := false;
    v_conditions_count := 0;

    IF v_rule.ts ? 'trait_conditions' THEN
      FOR v_condition IN SELECT * FROM jsonb_array_elements(v_rule.ts->'trait_conditions')
      LOOP
        v_conditions_count := v_conditions_count + 1;
        v_condition_pass := false;
        v_op := v_condition->>'op';
        v_trait_value := NULL;

        CASE v_condition->>'trait'
          WHEN 'deadline_motivation' THEN v_trait_value := v_assessment.deadline_motivation;
          WHEN 'recognition_drive' THEN v_trait_value := v_assessment.recognition_drive;
          WHEN 'assertiveness' THEN v_trait_value := v_assessment.assertiveness;
          WHEN 'independent_spirit' THEN v_trait_value := v_assessment.independent_spirit;
          WHEN 'analytical' THEN v_trait_value := v_assessment.analytical;
          WHEN 'compassion' THEN v_trait_value := v_assessment.compassion;
          WHEN 'self_promotion' THEN v_trait_value := v_assessment.self_promotion;
          WHEN 'belief_in_others' THEN v_trait_value := v_assessment.belief_in_others;
          WHEN 'optimism' THEN v_trait_value := v_assessment.optimism;
          WHEN 'overall_score' THEN v_trait_value := v_assessment.overall_score;
          WHEN 'maintains_high_activity' THEN
            v_trait_value := (v_assessment.deadline_motivation + v_assessment.recognition_drive + v_assessment.assertiveness) / 3.0;
          ELSE v_trait_value := NULL;
        END CASE;

        IF v_condition->>'trait' = 'reliability' THEN
          IF v_op = 'eq' THEN
            v_condition_pass := (v_assessment.reliability = v_condition->>'value');
          ELSIF v_op = 'in' AND v_condition ? 'values' THEN
            v_condition_pass := v_assessment.reliability = ANY(
              ARRAY(SELECT jsonb_array_elements_text(v_condition->'values'))
            );
          END IF;
        ELSIF v_condition->>'trait' = 'response_distortion' THEN
          IF v_op = 'eq' THEN
            v_condition_pass := (v_assessment.response_distortion = v_condition->>'value');
          END IF;
        ELSIF v_trait_value IS NOT NULL AND v_condition ? 'value' THEN
          v_value := (v_condition->>'value')::numeric;
          CASE v_op
            WHEN 'gte' THEN v_condition_pass := v_trait_value >= v_value;
            WHEN 'lte' THEN v_condition_pass := v_trait_value <= v_value;
            WHEN 'lt' THEN v_condition_pass := v_trait_value < v_value;
            WHEN 'gt' THEN v_condition_pass := v_trait_value > v_value;
            WHEN 'eq' THEN v_condition_pass := v_trait_value = v_value;
            WHEN 'between' THEN
              IF v_condition ? 'value2' THEN
                v_value2 := (v_condition->>'value2')::numeric;
                v_condition_pass := v_trait_value BETWEEN v_value AND v_value2;
              END IF;
            ELSE v_condition_pass := false;
          END CASE;
        ELSE
          v_all_pass := false;
        END IF;

        IF v_condition_pass THEN
          v_any_pass := true;
        ELSE
          v_all_pass := false;
        END IF;
      END LOOP;
    ELSE
      v_conditions_count := 0;
      v_all_pass := false;
    END IF;

    IF v_rule.ts ? 'additional_conditions' THEN
      IF v_rule.ts->'additional_conditions' ? 'leadership_style' THEN
        IF v_assessment.leadership_style IS DISTINCT FROM (v_rule.ts->'additional_conditions'->>'leadership_style') THEN
          v_all_pass := false;
        END IF;
      END IF;
    END IF;

    IF v_conditions_count > 0 AND ((v_logic = 'all' AND v_all_pass) OR (v_logic = 'any' AND v_any_pass)) THEN
      out_rule_id := v_rule.rid;
      out_rule_type := v_rule.rt;
      out_rule_name := v_rule.rn;
      out_short_label := v_rule.sl;
      out_match_confidence := 'full_match';
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
$$;
