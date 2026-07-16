-- =====================================================================
-- Phase 1c: Update cts_all_competencies to include adjusted values.
-- Preserves raw for backward compat; adds adjusted for new consumers.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cts_all_competencies(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'sales', public.cts_sales_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'service', public.cts_service_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'service_sales', public.cts_service_sales_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'aspirant', public.cts_aspirant_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'sales_adjusted',         public.cts_sales_competencies_adjusted(p_assessment_id),
    'service_adjusted',       public.cts_service_competencies_adjusted(p_assessment_id),
    'service_sales_adjusted', public.cts_service_sales_competencies_adjusted(p_assessment_id),
    'aspirant_adjusted',      public.cts_aspirant_competencies_adjusted(p_assessment_id)
  )
  FROM public.team_assessments ta
  WHERE ta.id = p_assessment_id
    AND ta.deadline_motivation IS NOT NULL;
$$;

-- =====================================================================
-- Phase 1d: Reclassify character_floor rules from hard_decline to informational.
-- They stay as probe triggers, not verdict decisions.
-- The new three-construct verdict function scores character from interview
-- columns (char_honesty/hwe/persres/concern), not CTS proxies.
-- =====================================================================
UPDATE public.hiregauge_rules
SET verdict_impact = 'informational',
    updated_at = NOW(),
    notes = COALESCE(notes || E'\n\n', '') || '2026-07-16: Reclassified from hard_decline to informational. Character is now measured via interview scorecard columns (char_honesty/char_hwe/char_persres/char_concern) with 7/10 floor. CTS-derived character floors become interview probe triggers, not verdict decisions.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'character_floor'
  AND verdict_impact = 'hard_decline';

-- =====================================================================
-- Phase 1e: hiregauge_three_construct_verdict function.
-- Returns weighted score across Nature/Nurture/Drivers with layer weights.
-- ========================================================================
CREATE OR REPLACE FUNCTION public.hiregauge_three_construct_verdict(p_assessment_id uuid)
RETURNS TABLE (
  assessment_id uuid,
  verdict text,
  score_0_10 numeric,
  score_hire_at_70 text,
  score_hire_at_75 text,
  score_hire_at_80 text,
  nature_score numeric,
  nurture_score numeric,
  drivers_score numeric,
  character_floor_status text,
  character_floor_failed text[],
  retrospective_context text,
  retrospective_override text,
  dimensions_scored integer,
  confidence text,
  meta jsonb
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_ta record;
  v_team_id uuid;
  v_is_active boolean;
  v_is_archived boolean;
  v_retro_context text;
  -- Layer scores per construct (0-10)
  v_nature_resume numeric;
  v_nature_assessment numeric;
  v_nature_interview numeric;
  v_nurture_resume numeric;
  v_nurture_assessment numeric;
  v_nurture_interview numeric;
  v_drivers_resume numeric;
  v_drivers_assessment numeric;
  v_drivers_interview numeric;
  -- Weights per layer per construct (sum to 1.0 within construct)
  v_nature_r_w numeric := 0.05;
  v_nature_a_w numeric := 0.75;
  v_nature_i_w numeric := 0.20;
  v_nurture_r_w numeric := 0.15;
  v_nurture_a_w numeric := 0.25;
  v_nurture_i_w numeric := 0.60;
  v_drivers_r_w numeric := 0.15;
  v_drivers_a_w numeric := 0.30;
  v_drivers_i_w numeric := 0.55;
  -- Construct weights (35/30/35)
  v_nature_w numeric := 0.35;
  v_nurture_w numeric := 0.30;
  v_drivers_w numeric := 0.35;
  -- Assessment sub-input weights within Nature
  v_asub_os_w numeric := 0.55;
  v_asub_comp_w numeric := 0.35;
  v_asub_lss_w numeric := 0.10;
  -- Working vars
  v_best_fit_role text;
  v_best_fit_os numeric;
  v_sales_comp_avg numeric;
  v_lss_score numeric;
  v_lss_acc numeric;
  v_role_comp_json jsonb;
  v_nature_dimensions_scored int := 0;
  v_nurture_dimensions_scored int := 0;
  v_drivers_dimensions_scored int := 0;
  v_char_floors_failed text[] := ARRAY[]::text[];
  v_char_floor_status text;
  v_score numeric;
  v_verdict text;
  v_confidence text;
BEGIN
  SELECT * INTO v_ta FROM public.team_assessments WHERE id = p_assessment_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Retrospective context: is this candidate a current active team member?
  SELECT t.id, (t.archived_at IS NULL AND COALESCE(t.is_active, false)) AS active, (t.archived_at IS NOT NULL) AS archived
    INTO v_team_id, v_is_active, v_is_archived
    FROM public.team t WHERE t.id = v_ta.team_member_id;

  v_retro_context := CASE
    WHEN v_is_active THEN 'hired_and_performing'
    WHEN v_is_archived THEN 'former_team'
    ELSE NULL
  END;

  -- ======================================================================
  -- NATURE construct
  -- ========================================================================
  -- Resume layer: pulls from resume_quality if scored
  IF v_ta.resume_quality IS NOT NULL THEN
    v_nature_resume := v_ta.resume_quality::numeric;
    v_nature_dimensions_scored := v_nature_dimensions_scored + 1;
  END IF;

  -- Assessment layer: best-fit role OS + adjusted competencies + LSS
  IF v_ta.deadline_motivation IS NOT NULL THEN
    SELECT bfr.best_role, bfr.best_score INTO v_best_fit_role, v_best_fit_os
      FROM public.cts_best_fit_role(p_assessment_id) bfr;

    -- Adjusted competencies for best-fit role
    v_role_comp_json := CASE v_best_fit_role
      WHEN 'sales' THEN public.cts_sales_competencies_adjusted(p_assessment_id)
      WHEN 'service' THEN public.cts_service_competencies_adjusted(p_assessment_id)
      WHEN 'service_sales' THEN public.cts_service_sales_competencies_adjusted(p_assessment_id)
      WHEN 'aspirant' THEN public.cts_aspirant_competencies_adjusted(p_assessment_id)
    END;

    -- Average of numeric competency values (exclude _meta key)
    SELECT AVG((val)::numeric) INTO v_sales_comp_avg
      FROM jsonb_each_text(v_role_comp_json) e(key, val)
     WHERE e.key <> '_meta';

    -- LSS score 0-10 from accuracy (35 = 10/10)
    v_lss_acc := COALESCE(v_ta.lss_total_accuracy, 0);
    v_lss_score := LEAST(10.0, GREATEST(0.0, v_lss_acc / 3.5));

    -- Combine into Nature assessment score (0-10)
    v_nature_assessment := (
      COALESCE(v_best_fit_os / 10.0, 0) * v_asub_os_w
      + COALESCE(v_sales_comp_avg / 10.0, 0) * v_asub_comp_w
      + v_lss_score * v_asub_lss_w
    );
    v_nature_dimensions_scored := v_nature_dimensions_scored + 1;
  END IF;

  -- Interview layer: role play average
  IF v_ta.rp_needs IS NOT NULL OR v_ta.rp_presentation IS NOT NULL OR v_ta.rp_closing IS NOT NULL OR v_ta.rp_objection IS NOT NULL THEN
    v_nature_interview := (
      COALESCE(v_ta.rp_needs, 0)
      + COALESCE(v_ta.rp_presentation, 0)
      + COALESCE(v_ta.rp_closing, 0)
      + COALESCE(v_ta.rp_objection, 0)
    )::numeric / NULLIF((
      (CASE WHEN v_ta.rp_needs IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN v_ta.rp_presentation IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN v_ta.rp_closing IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN v_ta.rp_objection IS NULL THEN 0 ELSE 1 END)
    ), 0);
    v_nature_dimensions_scored := v_nature_dimensions_scored + 1;
  END IF;

  -- Nature construct score: weighted avg over layers with data
  DECLARE
    v_wsum numeric := 0;
    v_score_sum numeric := 0;
  BEGIN
    IF v_nature_resume IS NOT NULL THEN
      v_score_sum := v_score_sum + v_nature_resume * v_nature_r_w;
      v_wsum := v_wsum + v_nature_r_w;
    END IF;
    IF v_nature_assessment IS NOT NULL THEN
      v_score_sum := v_score_sum + v_nature_assessment * v_nature_a_w;
      v_wsum := v_wsum + v_nature_a_w;
    END IF;
    IF v_nature_interview IS NOT NULL THEN
      v_score_sum := v_score_sum + v_nature_interview * v_nature_i_w;
      v_wsum := v_wsum + v_nature_i_w;
    END IF;
    nature_score := CASE WHEN v_wsum > 0 THEN v_score_sum / v_wsum ELSE NULL END;
  END;

  -- =======================================================================
  -- NURTURE construct (character)
  -- ========================================================================
  -- Character floor check
  IF v_ta.char_honesty IS NOT NULL AND v_ta.char_honesty < 7 THEN
    v_char_floors_failed := array_append(v_char_floors_failed, 'char_honesty');
  END IF;
  IF v_ta.char_hwe IS NOT NULL AND v_ta.char_hwe < 7 THEN
    v_char_floors_failed := array_append(v_char_floors_failed, 'char_hwe');
  END IF;
  IF v_ta.char_persres IS NOT NULL AND v_ta.char_persres < 7 THEN
    v_char_floors_failed := array_append(v_char_floors_failed, 'char_persres');
  END IF;
  IF v_ta.char_concern IS NOT NULL AND v_ta.char_concern < 7 THEN
    v_char_floors_failed := array_append(v_char_floors_failed, 'char_concern');
  END IF;

  v_char_floor_status := CASE
    WHEN array_length(v_char_floors_failed, 1) > 0 THEN 'floor_failed'
    WHEN v_ta.char_honesty IS NOT NULL OR v_ta.char_hwe IS NOT NULL 
         OR v_ta.char_persres IS NOT NULL OR v_ta.char_concern IS NOT NULL THEN 'floor_passed'
    ELSE 'not_scored'
  END;

  -- Resume layer for Nurture: same resume_quality
  IF v_ta.resume_quality IS NOT NULL THEN
    v_nurture_resume := v_ta.resume_quality::numeric;
    v_nurture_dimensions_scored := v_nurture_dimensions_scored + 1;
  END IF;

  -- Assessment layer for Nurture: CTS proxy for character (mid-range signal)
  -- Uses CTS Reliability + BO + Compassion as proxies. Best signal is when CTS is high-reliability + low-distortion.
  -- Convert: high reliability + low distortion = 7; moderate = 5; low = 3
  IF v_ta.reliability IS NOT NULL THEN
    v_nurture_assessment := CASE
      WHEN v_ta.reliability IN ('high','very_high') AND v_ta.response_distortion = 'low' THEN 7
      WHEN v_ta.reliability = 'moderate' AND v_ta.response_distortion IN ('low','moderate') THEN 5
      WHEN v_ta.response_distortion = 'high' THEN 2
      ELSE 4
    END;
    v_nurture_dimensions_scored := v_nurture_dimensions_scored + 1;
  END IF;

  -- Interview layer for Nurture: average of 4 character scores
  IF v_ta.char_honesty IS NOT NULL OR v_ta.char_hwe IS NOT NULL 
     OR v_ta.char_persres IS NOT NULL OR v_ta.char_concern IS NOT NULL THEN
    v_nurture_interview := (
      COALESCE(v_ta.char_honesty, 0) + COALESCE(v_ta.char_hwe, 0)
      + COALESCE(v_ta.char_persres, 0) + COALESCE(v_ta.char_concern, 0)
    )::numeric / NULLIF((
      (CASE WHEN v_ta.char_honesty IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN v_ta.char_hwe IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN v_ta.char_persres IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN v_ta.char_concern IS NULL THEN 0 ELSE 1 END)
    ), 0);
    v_nurture_dimensions_scored := v_nurture_dimensions_scored + 1;
  END IF;

  DECLARE
    v_wsum numeric := 0;
    v_score_sum numeric := 0;
  BEGIN
    IF v_nurture_resume IS NOT NULL THEN
      v_score_sum := v_score_sum + v_nurture_resume * v_nurture_r_w;
      v_wsum := v_wsum + v_nurture_r_w;
    END IF;
    IF v_nurture_assessment IS NOT NULL THEN
      v_score_sum := v_score_sum + v_nurture_assessment * v_nurture_a_w;
      v_wsum := v_wsum + v_nurture_a_w;
    END IF;
    IF v_nurture_interview IS NOT NULL THEN
      v_score_sum := v_score_sum + v_nurture_interview * v_nurture_i_w;
      v_wsum := v_wsum + v_nurture_i_w;
    END IF;
    nurture_score := CASE WHEN v_wsum > 0 THEN v_score_sum / v_wsum ELSE NULL END;
  END;

  -- =====================================================================
  -- DRIVERS construct (motivation)
  -- ======================================================================
  IF v_ta.resume_quality IS NOT NULL THEN
    v_drivers_resume := v_ta.resume_quality::numeric;
    v_drivers_dimensions_scored := v_drivers_dimensions_scored + 1;
  END IF;

  -- Assessment: CTS motivation traits (DM, RD, IS avg)
  IF v_ta.deadline_motivation IS NOT NULL THEN
    v_drivers_assessment := (
      COALESCE(v_ta.deadline_motivation, 0)
      + COALESCE(v_ta.recognition_drive, 0)
      + COALESCE(v_ta.independent_spirit, 0)
    )::numeric / 30.0; -- avg trait/10 -> 0-10 scale
    v_drivers_dimensions_scored := v_drivers_dimensions_scored + 1;
  END IF;

  -- Interview: motivation scorecard columns
  IF v_ta.mot_level IS NOT NULL OR v_ta.mot_attitude_sales IS NOT NULL OR v_ta.mot_own_products IS NOT NULL THEN
    v_drivers_interview := (
      COALESCE(v_ta.mot_level, 0)
      + COALESCE(v_ta.mot_attitude_sales, 0)
      + COALESCE(v_ta.mot_own_products, 0)
    )::numeric / NULLIF((
      (CASE WHEN v_ta.mot_level IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN v_ta.mot_attitude_sales IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN v_ta.mot_own_products IS NULL THEN 0 ELSE 1 END)
    ), 0);
    v_drivers_dimensions_scored := v_drivers_dimensions_scored + 1;
  END IF;

  DECLARE
    v_wsum numeric := 0;
    v_score_sum numeric := 0;
  BEGIN
    IF v_drivers_resume IS NOT NULL THEN
      v_score_sum := v_score_sum + v_drivers_resume * v_drivers_r_w;
      v_wsum := v_wsum + v_drivers_r_w;
    END IF;
    IF v_drivers_assessment IS NOT NULL THEN
      v_score_sum := v_score_sum + v_drivers_assessment * v_drivers_a_w;
      v_wsum := v_wsum + v_drivers_a_w;
    END IF;
    IF v_drivers_interview IS NOT NULL THEN
      v_score_sum := v_score_sum + v_drivers_interview * v_drivers_i_w;
      v_wsum := v_wsum + v_drivers_i_w;
    END IF;
    drivers_score := CASE WHEN v_wsum > 0 THEN v_score_sum / v_wsum ELSE NULL END;
  END;

  -- ====================================================================
  -- Overall weighted score across constructs (only over constructs with data)
  -- =====================================================================
  DECLARE
    v_wsum numeric := 0;
    v_score_sum numeric := 0;
  BEGIN
    IF nature_score IS NOT NULL THEN
      v_score_sum := v_score_sum + nature_score * v_nature_w;
      v_wsum := v_wsum + v_nature_w;
    END IF;
    IF nurture_score IS NOT NULL THEN
      v_score_sum := v_score_sum + nurture_score * v_nurture_w;
      v_wsum := v_wsum + v_nurture_w;
    END IF;
    IF drivers_score IS NOT NULL THEN
      v_score_sum := v_score_sum + drivers_score * v_drivers_w;
      v_wsum := v_wsum + v_drivers_w;
    END IF;
    score_0_10 := CASE WHEN v_wsum > 0 THEN v_score_sum / v_wsum ELSE NULL END;
  END;

  -- =====================================================================
  -- Verdict
  -- ========================================================================
  -- 1. Character floor override
  IF v_char_floor_status = 'floor_failed' THEN
    v_verdict := 'decline_character';
  -- 2. Retrospective override (explicit)
  ELSIF v_ta.retrospective_verdict_override = 'pass' THEN
    v_verdict := 'pass';
  ELSIF v_ta.retrospective_verdict_override = 'flag' THEN
    v_verdict := 'pass_flagged';
  ELSIF v_ta.retrospective_verdict_override = 'fail_confirmed' THEN
    v_verdict := 'decline_confirmed';
  -- 3. Score-based (provisional threshold: >=7.5 hire, 6.0-7.5 consider, <6.0 decline)
  ELSIF score_0_10 IS NULL THEN
    v_verdict := 'insufficient_data';
  ELSIF score_0_10 >= 7.5 THEN
    v_verdict := CASE WHEN v_retro_context = 'hired_and_performing' THEN 'pass' ELSE 'hire' END;
  ELSIF score_0_10 >= 6.0 THEN
    v_verdict := CASE WHEN v_retro_context = 'hired_and_performing' THEN 'pass' ELSE 'consider' END;
  ELSE
    v_verdict := CASE WHEN v_retro_context = 'hired_and_performing' THEN 'pass_flagged' ELSE 'decline' END;
  END IF;

  -- Preview at 3 threshold options for UI
  score_hire_at_70 := CASE WHEN score_0_10 IS NULL THEN 'n/a'
    WHEN score_0_10 >= 7.0 THEN 'hire' WHEN score_0_10 >= 5.5 THEN 'consider' ELSE 'decline' END;
  score_hire_at_75 := CASE WHEN score_0_10 IS NULL THEN 'n/a'
    WHEN score_0_10 >= 7.5 THEN 'hire' WHEN score_0_10 >= 6.0 THEN 'consider' ELSE 'decline' END;
  score_hire_at_80 := CASE WHEN score_0_10 IS NULL THEN 'n/a'
    WHEN score_0_10 >= 8.0 THEN 'hire' WHEN score_0_10 >= 6.5 THEN 'consider' ELSE 'decline' END;

  -- Confidence
  dimensions_scored := v_nature_dimensions_scored + v_nurture_dimensions_scored + v_drivers_dimensions_scored;
  v_confidence := CASE
    WHEN dimensions_scored >= 7 THEN 'high'
    WHEN dimensions_scored >= 4 THEN 'medium'
    ELSE 'low'
  END;

  assessment_id := p_assessment_id;
  verdict := v_verdict;
  character_floor_status := v_char_floor_status;
  character_floor_failed := v_char_floors_failed;
  retrospective_context := v_retro_context;
  retrospective_override := v_ta.retrospective_verdict_override;
  confidence := v_confidence;
  meta := jsonb_build_object(
    'nature_layers', jsonb_build_object('resume', v_nature_resume, 'assessment', v_nature_assessment, 'interview', v_nature_interview),
    'nurture_layers', jsonb_build_object('resume', v_nurture_resume, 'assessment', v_nurture_assessment, 'interview', v_nurture_interview),
    'drivers_layers', jsonb_build_object('resume', v_drivers_resume, 'assessment', v_drivers_assessment, 'interview', v_drivers_interview),
    'construct_weights', jsonb_build_object('nature', v_nature_w, 'nurture', v_nurture_w, 'drivers', v_drivers_w),
    'thresholds_used', jsonb_build_object('hire', 7.5, 'consider', 6.0),
    'best_fit_role', v_best_fit_role,
    'best_fit_os', v_best_fit_os,
    'lss_accuracy', v_lss_acc,
    'reliability', v_ta.reliability,
    'response_distortion', v_ta.response_distortion
  );

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.hiregauge_three_construct_verdict(uuid) IS
'Three-construct (Nature/Nurture/Drivers) weighted verdict per Suggs. Construct weights 35/30/35. Layer weights within each construct favor Assessment for Nature (75%), Interview for Nurture/Drivers (55-60%). Character floor at 7/10 on interview-scored columns. Retrospective override supported for hired members. Ships with provisional thresholds 7.5/6.0.';