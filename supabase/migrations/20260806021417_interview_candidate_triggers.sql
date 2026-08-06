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
    -- enterprising is a direct flat column on hiring_candidates (verified live schema
    -- 2026-08-05 -- handoff doc's claim that it lives outside flat columns was stale)
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

  -- ===== Old-instrument path (deadline_motivation IS NOT NULL) =====
  IF v_row.deadline_motivation IS NOT NULL THEN
    IF v_row.deadline_motivation < 70 THEN
      v_codes := array_append(v_codes, 'L_LOW_DEADLINE');
    END IF;
    IF v_row.recognition_drive IS NOT NULL AND v_row.recognition_drive < 50 THEN
      v_codes := array_append(v_codes, 'L_LOW_RECOGNITION');
    END IF;
    IF v_row.assertiveness IS NOT NULL AND v_row.assertiveness < 50 THEN
      v_codes := array_append(v_codes, 'L_LOW_ASSERT');
    END IF;
    IF v_row.independent_spirit IS NOT NULL AND v_row.independent_spirit < 50 THEN
      v_codes := array_append(v_codes, 'L_LOW_IND');
    END IF;
    IF v_row.analytical IS NOT NULL AND v_row.analytical > 60 THEN
      v_codes := array_append(v_codes, 'L_HIGH_ANALYTICAL');
    END IF;
    IF v_row.compassion IS NOT NULL AND v_row.compassion < 30 THEN
      v_codes := array_append(v_codes, 'L_LOW_COMPASSION');
    END IF;
    IF v_row.compassion IS NOT NULL AND v_row.compassion > 70 THEN
      v_codes := array_append(v_codes, 'L_HIGH_COMPASSION');
    END IF;
    IF v_row.self_promotion IS NOT NULL AND v_row.self_promotion < 10 THEN
      v_codes := array_append(v_codes, 'L_LOW_SELFPROMO');
    END IF;
    IF v_row.self_promotion IS NOT NULL AND v_row.self_promotion > 80 THEN
      v_codes := array_append(v_codes, 'L_HIGH_SELFPROMO');
    END IF;
    IF v_row.belief_in_others IS NOT NULL AND v_row.belief_in_others < 20 THEN
      v_codes := array_append(v_codes, 'L_LOW_BELIEF');
    END IF;
    IF v_row.belief_in_others IS NOT NULL AND v_row.belief_in_others > 80 THEN
      v_codes := array_append(v_codes, 'L_HIGH_BELIEF');
    END IF;
    IF v_row.optimism IS NOT NULL AND v_row.optimism < 20 THEN
      v_codes := array_append(v_codes, 'L_LOW_OPTIMISM');
    END IF;
    IF v_row.optimism IS NOT NULL AND v_row.optimism > 80 THEN
      v_codes := array_append(v_codes, 'L_HIGH_OPTIMISM');
    END IF;
    IF (v_row.lss_total_accuracy IS NOT NULL AND v_row.lss_total_accuracy < 25)
       OR (v_row.lss_math_speed_seconds IS NOT NULL AND v_row.lss_math_speed_seconds > 60)
       OR (v_row.lss_verbal_speed_seconds IS NOT NULL AND v_row.lss_verbal_speed_seconds > 60)
       OR (v_row.lss_problem_solving_speed_seconds IS NOT NULL AND v_row.lss_problem_solving_speed_seconds > 60)
    THEN
      v_codes := array_append(v_codes, 'L_LSS_SPEED');
    END IF;
  END IF;

  -- ===== Validity trigger (either path) =====
  IF v_row.reliability IN ('moderate','low') OR v_row.response_distortion IN ('moderate','high') THEN
    v_codes := array_append(v_codes, 'L_VALIDITY');
  END IF;

  -- ===== Resume-vs-assessment gap triggers (both paths, only if both sides present) =====
  -- No commitment-construct or character-construct composite score column exists yet on
  -- hiring_candidates (verified live schema 2026-08-05: no iv_commitment, no character_*
  -- composite). Per handoff instruction, skip rather than fabricate -- these two triggers
  -- structurally cannot fire until those columns exist. Left in place, commented, so the
  -- trigger fires automatically the day those columns land.
  -- T_GAP_COMMITMENT / T_GAP_CHARACTER: not implemented (no source column yet).

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

  -- Dedupe, preserve nothing-fancy order
  SELECT array_agg(DISTINCT c) INTO v_codes FROM unnest(v_codes) AS c;
  RETURN COALESCE(v_codes, ARRAY[]::text[]);
END;
$function$;
