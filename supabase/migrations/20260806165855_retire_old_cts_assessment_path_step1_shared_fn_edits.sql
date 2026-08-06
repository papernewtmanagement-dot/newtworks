-- Step 1 of old-CTS-assessment retirement: strip the old-instrument branch out of
-- functions that are genuinely dual-path (shared code, not old-only). These are
-- edited, not dropped, per standing dual-path-scoring instruction.

-- 1a. _hiregauge_get_trait_value: drop all old-CTS trait branches + the
-- lss_total_accuracy / maintains_high_activity branches (columns/fn being retired
-- in later steps). overall_score is a generic legacy field, kept as-is.
CREATE OR REPLACE FUNCTION public._hiregauge_get_trait_value(p_ta hiring_candidates, p_trait text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_trait
    WHEN 'overall_score' THEN p_ta.overall_score::numeric
    ELSE NULL
  END;
$function$;

-- 1b. hiregauge_evaluate_candidate: remove the two additional_conditions blocks
-- that read deadline_motivation / recognition_drive directly (old-CTS engine-floor
-- concept). These columns are being dropped; leaving the references would break
-- the function outright. The rules that relied on these conditions are being
-- deactivated in step 3.
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

    IF v_rule.ts ? 'additional_conditions' THEN
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

-- 1c. assessment_commitment: drop the old-instrument branch.
CREATE OR REPLACE FUNCTION public.assessment_commitment(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  -- Old-instrument (deadline_motivation) branch retired 2026-08-06 -- old CTS
  -- path fully decommissioned (no live producer; SF-forwarded-CTS intake
  -- confirmed dead by Peter). New-instrument branch unchanged.
  SELECT
    round(
      (COALESCE(hc.enterprising,0) + COALESCE(hc.achievement_striving,0)
       + COALESCE(hc.competitiveness,0) + COALESCE(hc.prove_goal_orientation,0)
       + COALESCE(hc.learning_goal_orientation,0)
       + COALESCE(100 - hc.avoid_goal_orientation, 0))::numeric
      / NULLIF(
          (hc.enterprising IS NOT NULL)::int + (hc.achievement_striving IS NOT NULL)::int
          + (hc.competitiveness IS NOT NULL)::int + (hc.prove_goal_orientation IS NOT NULL)::int
          + (hc.learning_goal_orientation IS NOT NULL)::int + (hc.avoid_goal_orientation IS NOT NULL)::int,
        0)
    , 2)
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id
    AND hc.achievement_striving IS NOT NULL;
$function$;

-- 1d. assessment_best_fit_role: drop the v1 dispatch branch entirely.
CREATE OR REPLACE FUNCTION public.assessment_best_fit_role(p_assessment_id uuid)
 RETURNS TABLE(best_role text, best_role_category text, display_label text, best_fit_score integer, sales_outbound_fit_score integer, sales_inbound_fit_score integer, sales_in_book_fit_score integer, retention_reception_fit_score integer, retention_escalation_fit_score integer, retention_support_fit_score integer, aspirant_fit_score integer, best_verdict_cap text, best_hard_decline boolean, best_churn_risk boolean, best_gates_fired jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_candidate hiring_candidates;
  s_so jsonb; s_si jsonb; s_sib jsonb; s_rr jsonb; s_re jsonb; s_rs jsonb; s_asp jsonb;
  n_so int; n_si int; n_sib int; n_rr int; n_re int; n_rs int; n_asp int;
  best_r text; best_o int; best_gated jsonb;
  best_cat text; best_label text;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_assessment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment % not found', p_assessment_id;
  END IF;

  IF v_candidate.achievement_striving IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, NULL::text,
      NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int,
      NULL::text, NULL::boolean, NULL::boolean, NULL::jsonb;
    RETURN;
  END IF;

  s_so  := public.newtworks_role_fit_sales_outbound(v_candidate);
  s_si  := public.newtworks_role_fit_sales_inbound(v_candidate);
  s_sib := public.newtworks_role_fit_sales_in_book(v_candidate);
  s_rr  := public.newtworks_role_fit_retention_reception(v_candidate);
  s_re  := public.newtworks_role_fit_retention_escalation(v_candidate);
  s_rs  := public.newtworks_role_fit_retention_support(v_candidate);
  s_asp := public.newtworks_role_fit_aspirant(v_candidate);

  n_so  := ROUND((NULLIF(s_so ->>'fit_score',''))::numeric)::int;
  n_si  := ROUND((NULLIF(s_si ->>'fit_score',''))::numeric)::int;
  n_sib := ROUND((NULLIF(s_sib->>'fit_score',''))::numeric)::int;
  n_rr  := ROUND((NULLIF(s_rr ->>'fit_score',''))::numeric)::int;
  n_re  := ROUND((NULLIF(s_re ->>'fit_score',''))::numeric)::int;
  n_rs  := ROUND((NULLIF(s_rs ->>'fit_score',''))::numeric)::int;
  n_asp := ROUND((NULLIF(s_asp->>'fit_score',''))::numeric)::int;

  best_o := GREATEST(n_so, n_si, n_sib, n_rr, n_re, n_rs, n_asp);

  IF best_o IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, NULL::text,
      NULL::int, n_so, n_si, n_sib, n_rr, n_re, n_rs, n_asp,
      NULL::text, NULL::boolean, NULL::boolean, NULL::jsonb;
    RETURN;
  END IF;

  best_r := CASE
    WHEN best_o = n_so  THEN 'sales_outbound'
    WHEN best_o = n_si  THEN 'sales_inbound'
    WHEN best_o = n_sib THEN 'sales_in_book'
    WHEN best_o = n_rr  THEN 'retention_reception'
    WHEN best_o = n_re  THEN 'retention_escalation'
    WHEN best_o = n_rs  THEN 'retention_support'
    ELSE 'aspirant'
  END;

  best_gated := CASE best_r
    WHEN 'sales_outbound' THEN s_so WHEN 'sales_inbound' THEN s_si WHEN 'sales_in_book' THEN s_sib
    WHEN 'retention_reception' THEN s_rr WHEN 'retention_escalation' THEN s_re
    WHEN 'retention_support' THEN s_rs ELSE s_asp
  END;

  best_cat := CASE
    WHEN best_r IN ('sales_outbound','sales_inbound','sales_in_book') THEN 'sales'
    WHEN best_r IN ('retention_reception','retention_escalation','retention_support') THEN 'retention'
    ELSE 'aspirant'
  END;

  best_label := CASE best_r
    WHEN 'sales_outbound'       THEN 'Sales - Outbound'
    WHEN 'sales_inbound'        THEN 'Sales - Inbound'
    WHEN 'sales_in_book'        THEN 'Sales - In-Book'
    WHEN 'retention_reception'  THEN 'Retention - Reception'
    WHEN 'retention_escalation' THEN 'Retention - Escalation'
    WHEN 'retention_support'    THEN 'Retention - Support'
    ELSE 'Aspirant'
  END;

  RETURN QUERY SELECT
    best_r, best_cat, best_label, best_o,
    n_so, n_si, n_sib, n_rr, n_re, n_rs, n_asp,
    best_gated->>'verdict_cap',
    (best_gated->>'hard_decline')::boolean,
    (best_gated->>'churn_risk')::boolean,
    best_gated->'gates_fired';
END;
$function$;

-- 1e. interview_candidate_triggers: drop the old-instrument branch.
CREATE OR REPLACE FUNCTION public.interview_candidate_triggers(p_candidate_id uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_row public.hiring_candidates%ROWTYPE;
  v_codes text[] := ARRAY[]::text[];
  v_gma_n numeric;
  v_gma_pct numeric;
  v_resume jsonb;
  v_honesty numeric;
  v_follow_through numeric;
  v_trajectory numeric;
  v_coherent_pursuit numeric;
  v_personal_responsibility numeric;
  v_text_lower text;
  v_res_commit numeric;
  v_asm_commit numeric;
  v_res_char numeric;
  v_asm_char numeric;
BEGIN
  SELECT * INTO v_row FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN v_codes;
  END IF;

  -- ===== New-instrument path (achievement_striving IS NOT NULL) =====
  IF v_row.achievement_striving IS NOT NULL THEN
    IF v_row.impression_management_band = 'elevated' THEN
      v_codes := array_append(v_codes, 'T_IM_ELEVATED');
    END IF;
    IF v_row.integrity_flag IS TRUE OR v_row.integrity_gate_shadow_result = 'fail' THEN
      v_codes := array_append(v_codes, 'T_INTEGRITY_FLAG');
    END IF;
    IF v_row.churn_risk IS TRUE THEN
      v_codes := array_append(v_codes, 'T_CHURN_RISK');
    END IF;
    IF v_row.competency_gate_fired IS NOT NULL THEN
      v_codes := array_append(v_codes, 'T_COMPETENCY_GATE');
    END IF;

    IF v_row.gma_total_accuracy IS NOT NULL THEN
      SELECT count(*)::numeric INTO v_gma_n
      FROM public.hiregauge_candidate_responses r
      JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
      WHERE r.candidate_id = p_candidate_id
        AND i.section = 'newtworks_v2_cognitive_gma'
        AND i.cognitive_domain IS NOT NULL
        AND i.retest_of_item_number IS NULL;

      IF COALESCE(v_gma_n, 0) > 0 THEN
        v_gma_pct := v_row.gma_total_accuracy::numeric / v_gma_n;
        IF v_gma_pct < 0.50 THEN
          v_codes := array_append(v_codes, 'T_GMA_LOW');
        END IF;
      END IF;
    END IF;

    IF v_row.sjt_score IS NOT NULL AND v_row.sjt_score < 50 THEN
      v_codes := array_append(v_codes, 'T_SJT_LOW');
    END IF;
    IF v_row.self_discipline IS NOT NULL AND v_row.self_discipline < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_SELF_DISCIPLINE');
    END IF;
    IF v_row.achievement_striving IS NOT NULL AND v_row.achievement_striving < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_ACHIEVEMENT');
    END IF;
    IF v_row.dutifulness IS NOT NULL AND v_row.dutifulness < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_DUTIFULNESS');
    END IF;
    IF v_row.emotional_stability IS NOT NULL AND v_row.emotional_stability < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_EMOTIONAL_STABILITY');
    END IF;
    IF v_row.assertiveness IS NOT NULL AND v_row.assertiveness < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_ASSERTIVENESS_V2');
    END IF;
    IF v_row.compassion IS NOT NULL AND v_row.compassion < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_COMPASSION_V2');
    END IF;
    IF v_row.cooperation IS NOT NULL AND v_row.cooperation < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_COOPERATION');
    END IF;
    IF v_row.customer_orientation IS NOT NULL AND v_row.customer_orientation < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_CUSTOMER_ORIENTATION');
    END IF;
    IF v_row.proactive_personality IS NOT NULL AND v_row.proactive_personality < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_PROACTIVE');
    END IF;
    IF v_row.enterprising IS NOT NULL AND v_row.enterprising < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_ENTERPRISING');
    END IF;
    IF v_row.avoid_goal_orientation IS NOT NULL AND v_row.avoid_goal_orientation > 70 THEN
      v_codes := array_append(v_codes, 'T_AVOID_GOAL_HIGH');
    END IF;
    IF v_row.self_efficacy IS NOT NULL AND v_row.self_efficacy < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_SELF_EFFICACY');
    END IF;
    IF v_row.cautiousness IS NOT NULL AND v_row.cautiousness > 75 THEN
      v_codes := array_append(v_codes, 'T_HIGH_CAUTIOUSNESS');
    END IF;
  END IF;

  -- Old-instrument path retired 2026-08-06 (old CTS path fully decommissioned).

  -- ===== Validity trigger (either path) =====
  IF v_row.reliability IN ('moderate','low') OR v_row.response_distortion IN ('moderate','high') THEN
    v_codes := array_append(v_codes, 'L_VALIDITY');
  END IF;

  -- ===== Resume-vs-assessment gap triggers (either path) =====
  SELECT res_commitment, assessment_commitment, res_character, assessment_character
    INTO v_res_commit, v_asm_commit, v_res_char, v_asm_char
  FROM public.v_hiring_candidates
  WHERE id = p_candidate_id;

  IF v_res_commit IS NOT NULL AND v_asm_commit IS NOT NULL
     AND abs(v_res_commit - v_asm_commit) >= 25 THEN
    v_codes := array_append(v_codes, 'T_GAP_COMMITMENT');
  END IF;
  IF v_res_char IS NOT NULL AND v_asm_char IS NOT NULL
     AND abs(v_res_char - v_asm_char) >= 25 THEN
    v_codes := array_append(v_codes, 'T_GAP_CHARACTER');
  END IF;

  -- ===== Resume-only triggers (fire regardless of path) =====
  v_resume := v_row.resume_analysis;
  IF v_resume IS NOT NULL AND v_resume ? 'signals' THEN
    v_honesty := NULLIF(v_resume #>> '{signals,honesty,score}', '')::numeric;
    v_follow_through := NULLIF(v_resume #>> '{signals,follow_through,score}', '')::numeric;
    v_trajectory := NULLIF(v_resume #>> '{signals,trajectory_direction,score}', '')::numeric;
    v_coherent_pursuit := NULLIF(v_resume #>> '{signals,coherent_pursuit,score}', '')::numeric;
    v_personal_responsibility := NULLIF(v_resume #>> '{signals,personal_responsibility,score}', '')::numeric;

    IF v_honesty IS NOT NULL AND v_honesty < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_HONESTY_LOW');
    END IF;
    IF v_follow_through IS NOT NULL AND v_follow_through < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_FOLLOW_THROUGH_LOW');
    END IF;
    IF v_trajectory IS NOT NULL AND v_trajectory < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_TRAJECTORY_LOW');
    END IF;
    IF v_coherent_pursuit IS NOT NULL AND v_coherent_pursuit < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_COHERENT_PURSUIT_LOW');
    END IF;
    IF v_personal_responsibility IS NOT NULL AND v_personal_responsibility < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_RESPONSIBILITY_LOW');
    END IF;

    IF v_row.resume_extracted_text IS NOT NULL THEN
      v_text_lower := lower(v_row.resume_extracted_text);

      IF v_text_lower NOT LIKE '%sales%'
         AND v_text_lower NOT LIKE '%account executive%'
         AND v_text_lower NOT LIKE '%producer%'
      THEN
        v_codes := array_append(v_codes, 'T_RES_NO_SALES_HISTORY');
      END IF;

      IF v_text_lower LIKE '%led %' OR v_text_lower LIKE '%managed %' OR v_text_lower LIKE '%supervised %' THEN
        v_codes := array_append(v_codes, 'T_RES_LEADERSHIP_CLAIM');
      END IF;

      IF (v_text_lower LIKE '%\%%' OR v_text_lower LIKE '%$%')
         AND (v_text_lower LIKE '%sale%' OR v_text_lower LIKE '%sold%' OR v_text_lower LIKE '%revenue%' OR v_text_lower LIKE '%quota%')
         AND v_honesty IS NOT NULL AND v_honesty < 60
      THEN
        v_codes := array_append(v_codes, 'T_SALES_CLAIM_UNSUPPORTED');
      END IF;
    END IF;
  END IF;

  SELECT array_agg(DISTINCT c) INTO v_codes FROM unnest(v_codes) AS c;
  RETURN COALESCE(v_codes, ARRAY[]::text[]);
END;
$function$;
