-- Migration: hiregauge_mha_ols_fix_and_retrospective_context_20260715
-- 1. _hiregauge_get_trait_value MHA formula: naive avg → canonical OLS
--    Bug: Tommy (and any high-Analytical/low-Compassion profile) had CF-HWE
--    false-fail because DM+RD+ASS/3 = 51.7 vs OLS-canonical 55. Fix pulls
--    the value from cts_sales_competencies (single source of truth).
-- 2. cts_all_competencies(uuid): wrapper returning competencies for all four
--    role fits in one call. Consumed by CandidateDetail Role Fit section.
-- 3. hiregauge_composite_recommendation: adds retrospective_context field.
--    When assessment.team_member_id links to active, non-archived team row,
--    verdict = 'retrospective_read'. Framework signals still surface
--    (calibration data) but not framed as a hiring decision.
-- Requires DROP + CREATE for the composite (RETURNS TABLE column added).

CREATE OR REPLACE FUNCTION public._hiregauge_get_trait_value(p_ta team_assessments, p_trait text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_trait
    WHEN 'deadline_motivation'     THEN p_ta.deadline_motivation::numeric
    WHEN 'recognition_drive'       THEN p_ta.recognition_drive::numeric
    WHEN 'assertiveness'           THEN p_ta.assertiveness::numeric
    WHEN 'independent_spirit'      THEN p_ta.independent_spirit::numeric
    WHEN 'analytical'              THEN p_ta.analytical::numeric
    WHEN 'compassion'              THEN p_ta.compassion::numeric
    WHEN 'self_promotion'          THEN p_ta.self_promotion::numeric
    WHEN 'belief_in_others'        THEN p_ta.belief_in_others::numeric
    WHEN 'optimism'                THEN p_ta.optimism::numeric
    WHEN 'overall_score'           THEN p_ta.overall_score::numeric
    WHEN 'maintains_high_activity' THEN
      CASE
        WHEN p_ta.deadline_motivation IS NULL OR p_ta.recognition_drive IS NULL
          OR p_ta.assertiveness IS NULL OR p_ta.independent_spirit IS NULL
          OR p_ta.analytical IS NULL OR p_ta.compassion IS NULL
          OR p_ta.self_promotion IS NULL OR p_ta.belief_in_others IS NULL
          OR p_ta.optimism IS NULL THEN NULL
        ELSE (public.cts_sales_competencies(
          p_ta.deadline_motivation, p_ta.recognition_drive, p_ta.assertiveness,
          p_ta.independent_spirit, p_ta.analytical, p_ta.compassion,
          p_ta.self_promotion, p_ta.belief_in_others, p_ta.optimism
        )->>'maintains_high_activity')::numeric
      END
    ELSE NULL
  END;
$function$;

CREATE OR REPLACE FUNCTION public.cts_all_competencies(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
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
      ta.self_promotion, ta.belief_in_others, ta.optimism)
  )
  FROM public.team_assessments ta
  WHERE ta.id = p_assessment_id
    AND ta.deadline_motivation IS NOT NULL;
$function$;

DROP FUNCTION IF EXISTS public.hiregauge_composite_recommendation(uuid);

CREATE OR REPLACE FUNCTION public.hiregauge_composite_recommendation(p_assessment_id uuid)
 RETURNS TABLE(verdict text, primary_reason text, character_floors_failed text[], decline_signals text[], consider_signals text[], hire_signals text[], informational_signals text[], matched_rules_count integer, floor_failures_count integer, retrospective_context text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_row RECORD;
  v_impact TEXT;
  v_agency UUID;
  v_status TEXT;
  v_member_id UUID;
  v_member_active BOOLEAN;
  v_member_archived TIMESTAMPTZ;
  v_context TEXT := NULL;
  v_floors  TEXT[] := ARRAY[]::TEXT[];
  v_hard_floors TEXT[] := ARRAY[]::TEXT[];
  v_soft_floors TEXT[] := ARRAY[]::TEXT[];
  v_decline TEXT[] := ARRAY[]::TEXT[];
  v_consider TEXT[] := ARRAY[]::TEXT[];
  v_hire    TEXT[] := ARRAY[]::TEXT[];
  v_info    TEXT[] := ARRAY[]::TEXT[];
  v_hard_decline_count INT := 0;
  v_hard_hire_count INT := 0;
  v_matched_count INT := 0;
  v_floor_count INT := 0;
  v_soft_decline_count INT := 0;
  v_verdict TEXT;
  v_reason  TEXT;
BEGIN
  SELECT ta.agency_id, ta.status, ta.team_member_id
    INTO v_agency, v_status, v_member_id
  FROM public.team_assessments ta
  WHERE ta.id = p_assessment_id;

  -- Retrospective context lookup: is this a currently-employed team member?
  IF v_member_id IS NOT NULL THEN
    SELECT t.is_active, t.archived_at
      INTO v_member_active, v_member_archived
    FROM public.team t
    WHERE t.id = v_member_id;

    IF COALESCE(v_member_active, false) = true AND v_member_archived IS NULL THEN
      v_context := 'hired_and_performing';
    ELSIF v_member_archived IS NOT NULL THEN
      v_context := 'former_team';
    END IF;
  END IF;

  FOR v_row IN
    SELECT * FROM public.hiregauge_evaluate_candidate(p_assessment_id)
  LOOP
    v_impact := NULL;
    SELECT verdict_impact INTO v_impact
    FROM public.hiregauge_rules
    WHERE agency_id = v_agency
      AND is_active = true
      AND ((v_row.out_short_label IS NOT NULL AND short_label = v_row.out_short_label)
           OR (v_row.out_short_label IS NULL AND rule_name = v_row.out_rule_name))
    ORDER BY updated_at DESC
    LIMIT 1;
    v_impact := COALESCE(v_impact, 'informational');

    IF v_row.out_pass = false AND v_row.out_rule_type = 'character_floor' THEN
      v_floors := v_floors || COALESCE(v_row.out_short_label, v_row.out_rule_name);
      v_floor_count := v_floor_count + 1;
      IF v_impact = 'hard_decline' THEN
        v_hard_floors := v_hard_floors || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        v_hard_decline_count := v_hard_decline_count + 1;
      ELSE
        v_soft_floors := v_soft_floors || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        v_decline := v_decline || (COALESCE(v_row.out_short_label, v_row.out_rule_name) || ' (unverified)');
        v_soft_decline_count := v_soft_decline_count + 1;
      END IF;

    ELSIF v_row.out_pass = true AND v_row.out_rule_type = 'character_floor' THEN
      CONTINUE;

    ELSIF v_row.out_pass = true THEN
      v_matched_count := v_matched_count + 1;
      CASE v_impact
        WHEN 'hard_decline' THEN
          v_decline := v_decline || COALESCE(v_row.out_short_label, v_row.out_rule_name);
          v_hard_decline_count := v_hard_decline_count + 1;
        WHEN 'soft_decline' THEN
          v_decline := v_decline || COALESCE(v_row.out_short_label, v_row.out_rule_name);
          v_soft_decline_count := v_soft_decline_count + 1;
        WHEN 'consider' THEN
          v_consider := v_consider || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'soft_hire' THEN
          v_hire := v_hire || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'hard_hire' THEN
          v_hire := v_hire || COALESCE(v_row.out_short_label, v_row.out_rule_name);
          v_hard_hire_count := v_hard_hire_count + 1;
        ELSE
          v_info := v_info || COALESCE(v_row.out_short_label, v_row.out_rule_name);
      END CASE;
    END IF;
  END LOOP;

  IF v_context = 'hired_and_performing' THEN
    v_verdict := 'retrospective_read';
    v_reason := 'Currently hired and active team member. Framework signals shown are retrospective calibration data, not a hiring decision — reality of work overrides framework decline.';
  ELSIF v_hard_decline_count > 0 THEN
    v_verdict := 'decline';
    IF array_length(v_hard_floors, 1) > 0 AND array_length(v_soft_floors, 1) > 0 THEN
      v_reason := format('Verified character floor(s) failed: %s (also unverified: %s)',
                         array_to_string(v_hard_floors, ', '),
                         array_to_string(v_soft_floors, ', '));
    ELSIF array_length(v_hard_floors, 1) > 0 THEN
      v_reason := format('Verified character floor(s) failed: %s',
                         array_to_string(v_hard_floors, ', '));
    ELSE
      v_reason := format('Verified decline pattern matched: %s', array_to_string(v_decline, ', '));
    END IF;
  ELSIF v_hard_hire_count > 0 THEN
    v_verdict := 'hire';
    v_reason := format('Verified hire pattern matched: %s', array_to_string(v_hire, ', '));
  ELSIF array_length(v_hire, 1) > 0 AND v_soft_decline_count = 0 THEN
    v_verdict := 'consider';
    v_reason := format('Green flag(s) with no counter-signals: %s — proceed to interview',
                       array_to_string(v_hire, ', '));
  ELSIF array_length(v_hire, 1) > 0 THEN
    v_verdict := 'consider';
    v_reason := format('Green flag(s) [%s] alongside unverified concern(s) [%s] — structured interview',
                       array_to_string(v_hire, ', '), array_to_string(v_decline, ', '));
  ELSIF v_soft_decline_count >= 3 THEN
    v_verdict := 'consider';
    v_reason := format('Multiple unverified decline signals (%s) — heavy probe recommended, verdict withheld pending interview',
                       array_to_string(v_decline, ', '));
  ELSIF v_soft_decline_count > 0 THEN
    v_verdict := 'consider';
    v_reason := format('Unverified decline signal(s): %s — probe in interview',
                       array_to_string(v_decline, ', '));
  ELSIF array_length(v_consider, 1) > 0 THEN
    v_verdict := 'consider';
    v_reason := format('Coaching signals: %s', array_to_string(v_consider, ', '));
  ELSE
    v_verdict := 'consider';
    v_reason := 'No decisive rule matches — proceed to standard interview process';
  END IF;

  verdict := v_verdict;
  primary_reason := v_reason;
  character_floors_failed := v_floors;
  decline_signals := v_decline;
  consider_signals := v_consider;
  hire_signals := v_hire;
  informational_signals := v_info;
  matched_rules_count := v_matched_count;
  floor_failures_count := v_floor_count;
  retrospective_context := v_context;
  RETURN NEXT;
END;
$function$;
