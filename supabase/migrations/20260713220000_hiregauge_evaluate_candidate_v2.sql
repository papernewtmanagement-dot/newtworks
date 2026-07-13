-- ============================================================================
-- 20260713220000_hiregauge_evaluate_candidate_v2.sql
-- HireGauge evaluate_candidate v2
-- Adds: special aggregate support, character-floor FAIL return, composite recommendation
-- Handoff from 2026-07-13 late-evening thread: items 1+2+3+6 of hiregauge_evaluate_candidate v2
-- ============================================================================

-- Step 1: Fix CF-PersRes trait_signature (was NULL — couldn't be evaluated)
-- Rule description: "Both paths must have some capacity." — AN and IS both need > floor.
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object(
  'logic', 'all',
  'trait_conditions', jsonb_build_array(
    jsonb_build_object('op', 'gt', 'trait', 'analytical', 'value', 25),
    jsonb_build_object('op', 'gt', 'trait', 'independent_spirit', 'value', 25)
  )
),
updated_at = NOW()
WHERE id = 'df253c7f-f404-42ee-88ee-e433f9d270f6'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- Step 2: Helper — trait value lookup by name
CREATE OR REPLACE FUNCTION public._hiregauge_get_trait_value(
  p_ta public.team_assessments,
  p_trait text
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_trait
    WHEN 'deadline_motivation'     THEN p_ta.deadline_motivation
    WHEN 'recognition_drive'       THEN p_ta.recognition_drive
    WHEN 'assertiveness'           THEN p_ta.assertiveness
    WHEN 'independent_spirit'      THEN p_ta.independent_spirit
    WHEN 'analytical'              THEN p_ta.analytical
    WHEN 'compassion'              THEN p_ta.compassion
    WHEN 'self_promotion'          THEN p_ta.self_promotion
    WHEN 'belief_in_others'        THEN p_ta.belief_in_others
    WHEN 'optimism'                THEN p_ta.optimism
    WHEN 'overall_score'           THEN p_ta.overall_score
    WHEN 'maintains_high_activity' THEN
      (COALESCE(p_ta.deadline_motivation,0)
       + COALESCE(p_ta.recognition_drive,0)
       + COALESCE(p_ta.assertiveness,0)) / 3.0
    ELSE NULL
  END;
$$;

-- Step 3: Drop old function (signature is changing — add out_pass column)
DROP FUNCTION IF EXISTS public.hiregauge_evaluate_candidate(uuid);

-- Step 4: Rewrite evaluate_candidate v2
CREATE OR REPLACE FUNCTION public.hiregauge_evaluate_candidate(p_assessment_id uuid)
RETURNS TABLE(
  out_rule_id uuid,
  out_rule_type text,
  out_rule_name text,
  out_short_label text,
  out_match_confidence text,
  out_pass boolean,
  out_description text,
  out_recommendation text,
  out_diagnostic_action text,
  out_interview_probe text,
  out_coaching_prescription text,
  out_calibration_status text,
  out_n_count integer,
  out_hiring_stage text[]
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_assessment  public.team_assessments;
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
  SELECT * INTO v_assessment FROM public.team_assessments WHERE id = p_assessment_id;
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

    -- ----- trait_conditions -----
    IF v_rule.ts ? 'trait_conditions' THEN
      FOR v_condition IN SELECT * FROM jsonb_array_elements(v_rule.ts->'trait_conditions')
      LOOP
        v_conditions_count := v_conditions_count + 1;
        v_condition_pass := false;
        v_op    := v_condition->>'op';
        v_trait := v_condition->>'trait';

        -- Non-numeric traits
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

        -- SPECIAL AGGREGATE: multi_ceiling
        --   { trait:'multi_ceiling', op:'count_gte', group:[...], threshold:90, value:2 }
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

        -- SPECIAL AGGREGATE: ceiling_count
        --   { trait:'ceiling_count', op:'gte', traits:[...], value:3, threshold?:85 }
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

        -- SPECIAL AGGREGATE: any_drive_trait
        --   { trait:'any_drive_trait', op:'gte', traits:[...], value:55 }
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

        -- Normal numeric condition
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

    -- ----- additional_conditions -----
    IF v_rule.ts ? 'additional_conditions' THEN
      -- leadership_style equality
      IF v_rule.ts->'additional_conditions' ? 'leadership_style' THEN
        IF v_assessment.leadership_style IS DISTINCT FROM (v_rule.ts->'additional_conditions'->>'leadership_style') THEN
          v_addl_pass := false;
        END IF;
      END IF;

      -- engine_floors_present: TRUE => at least one drive engine <= 40
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

      -- has_drive_trait_gte_55: TRUE => at least one drive trait >= 55
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

      -- two_of_ceilings: array of traits; require >=2 at ceiling (85)
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

    -- Determine overall match
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
      -- Character floors: return FAILURES too so decline signal is complete
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

-- Step 5: Composite recommendation aggregator
-- Single verdict from all rule matches + character-floor failures.
-- Returns one row with verdict + concise reasoning array.
CREATE OR REPLACE FUNCTION public.hiregauge_composite_recommendation(p_assessment_id uuid)
RETURNS TABLE(
  verdict text,
  primary_reason text,
  character_floors_failed text[],
  decline_signals text[],
  consider_signals text[],
  hire_signals text[],
  matched_rules_count integer,
  floor_failures_count integer
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_row RECORD;
  v_floors  TEXT[] := ARRAY[]::TEXT[];
  v_decline TEXT[] := ARRAY[]::TEXT[];
  v_consider TEXT[] := ARRAY[]::TEXT[];
  v_hire    TEXT[] := ARRAY[]::TEXT[];
  v_matched_count INT := 0;
  v_floor_count INT := 0;
  v_verdict TEXT;
  v_reason  TEXT;
BEGIN
  FOR v_row IN
    SELECT * FROM public.hiregauge_evaluate_candidate(p_assessment_id)
  LOOP
    IF v_row.out_pass = false AND v_row.out_rule_type = 'character_floor' THEN
      v_floors := v_floors || COALESCE(v_row.out_short_label, v_row.out_rule_name);
      v_floor_count := v_floor_count + 1;
    ELSIF v_row.out_pass = true THEN
      v_matched_count := v_matched_count + 1;
      CASE v_row.out_rule_type
        WHEN 'archetype' THEN
          IF v_row.out_rule_name ILIKE '%Non-Starter%'
             OR v_row.out_rule_name ILIKE '%Exit%'
             OR v_row.out_recommendation ILIKE 'decline%'
             OR v_row.out_recommendation ILIKE 'do not%'
          THEN
            v_decline := v_decline || COALESCE(v_row.out_short_label, v_row.out_rule_name);
          ELSE
            v_hire := v_hire || COALESCE(v_row.out_short_label, v_row.out_rule_name);
          END IF;
        WHEN 'exit_mode' THEN
          v_decline := v_decline || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'filter_rule' THEN
          IF v_row.out_recommendation ILIKE 'decline%'
             OR v_row.out_recommendation ILIKE 'do not%'
             OR v_row.out_description ILIKE '%decline%'
          THEN
            v_decline := v_decline || COALESCE(v_row.out_short_label, v_row.out_rule_name);
          ELSE
            v_consider := v_consider || COALESCE(v_row.out_short_label, v_row.out_rule_name);
          END IF;
        WHEN 'coaching_variant' THEN
          v_consider := v_consider || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'strategic_seat_pattern' THEN
          v_consider := v_consider || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'diagnostic_tool' THEN
          v_consider := v_consider || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        ELSE
          NULL;
      END CASE;
    END IF;
  END LOOP;

  IF v_floor_count > 0 THEN
    v_verdict := 'decline';
    v_reason  := format('%s character floor%s failed: %s',
                        v_floor_count,
                        CASE WHEN v_floor_count = 1 THEN '' ELSE 's' END,
                        array_to_string(v_floors, ', '));
  ELSIF array_length(v_decline, 1) > 0 THEN
    v_verdict := 'decline';
    v_reason  := format('Decline archetype matched: %s', array_to_string(v_decline, ', '));
  ELSIF array_length(v_hire, 1) > 0 AND array_length(v_consider, 1) IS NULL THEN
    v_verdict := 'hire';
    v_reason  := format('Positive archetype match: %s', array_to_string(v_hire, ', '));
  ELSIF array_length(v_hire, 1) > 0 THEN
    v_verdict := 'consider';
    v_reason  := format('Positive match (%s) with coaching signals (%s)',
                        array_to_string(v_hire, ', '),
                        array_to_string(v_consider, ', '));
  ELSIF array_length(v_consider, 1) > 0 THEN
    v_verdict := 'consider';
    v_reason  := format('Coaching/diagnostic signals only: %s', array_to_string(v_consider, ', '));
  ELSE
    v_verdict := 'consider';
    v_reason  := 'No decisive rule matches — proceed to standard interview process';
  END IF;

  verdict := v_verdict;
  primary_reason := v_reason;
  character_floors_failed := v_floors;
  decline_signals := v_decline;
  consider_signals := v_consider;
  hire_signals := v_hire;
  matched_rules_count := v_matched_count;
  floor_failures_count := v_floor_count;
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.hiregauge_evaluate_candidate(uuid) IS
'v2 (2026-07-13): adds special aggregate support (multi_ceiling, ceiling_count, any_drive_trait, engine_floors_present, has_drive_trait_gte_55, two_of_ceilings) + returns character_floor FAILURES with out_pass=false so decline signal is complete from single call.';

COMMENT ON FUNCTION public.hiregauge_composite_recommendation(uuid) IS
'v1 (2026-07-13): aggregates hiregauge_evaluate_candidate output into single verdict (decline|consider|hire) with reasoning breakdown. Character floor failures override all — any fail => decline.';
