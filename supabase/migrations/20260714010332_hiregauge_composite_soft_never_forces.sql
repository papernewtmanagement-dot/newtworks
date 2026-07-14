-- FINAL composite logic: unverified/soft signals never force decline on their own — they always
-- route to consider with interview probe language. Only verified hard signals (n>=2 RWV=true)
-- can force decline or hire. This aligns composite behavior with Peter's stated preference:
-- hard-and-fast verdicts require verification.

CREATE OR REPLACE FUNCTION public.hiregauge_composite_recommendation(p_assessment_id uuid)
RETURNS TABLE(
  verdict text, primary_reason text, character_floors_failed text[],
  decline_signals text[], consider_signals text[], hire_signals text[],
  informational_signals text[], matched_rules_count integer, floor_failures_count integer
)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_row RECORD; v_impact TEXT; v_agency UUID;
  v_floors TEXT[] := ARRAY[]::TEXT[];
  v_hard_floors TEXT[] := ARRAY[]::TEXT[];
  v_soft_floors TEXT[] := ARRAY[]::TEXT[];
  v_decline TEXT[] := ARRAY[]::TEXT[];
  v_consider TEXT[] := ARRAY[]::TEXT[];
  v_hire TEXT[] := ARRAY[]::TEXT[];
  v_info TEXT[] := ARRAY[]::TEXT[];
  v_hard_decline_count INT := 0; v_hard_hire_count INT := 0;
  v_matched_count INT := 0; v_floor_count INT := 0; v_soft_decline_count INT := 0;
  v_verdict TEXT; v_reason TEXT;
BEGIN
  SELECT agency_id INTO v_agency FROM public.team_assessments WHERE id = p_assessment_id;
  FOR v_row IN SELECT * FROM public.hiregauge_evaluate_candidate(p_assessment_id) LOOP
    v_impact := NULL;
    SELECT verdict_impact INTO v_impact FROM public.hiregauge_rules
    WHERE agency_id = v_agency AND is_active = true
      AND ((v_row.out_short_label IS NOT NULL AND short_label = v_row.out_short_label)
           OR (v_row.out_short_label IS NULL AND rule_name = v_row.out_rule_name))
    ORDER BY updated_at DESC LIMIT 1;
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
        WHEN 'consider' THEN v_consider := v_consider || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'soft_hire' THEN v_hire := v_hire || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'hard_hire' THEN
          v_hire := v_hire || COALESCE(v_row.out_short_label, v_row.out_rule_name);
          v_hard_hire_count := v_hard_hire_count + 1;
        ELSE v_info := v_info || COALESCE(v_row.out_short_label, v_row.out_rule_name);
      END CASE;
    END IF;
  END LOOP;

  IF v_hard_decline_count > 0 THEN
    v_verdict := 'decline';
    IF array_length(v_hard_floors, 1) > 0 AND array_length(v_soft_floors, 1) > 0 THEN
      v_reason := format('Verified character floor(s) failed: %s (also unverified: %s)',
                         array_to_string(v_hard_floors, ', '), array_to_string(v_soft_floors, ', '));
    ELSIF array_length(v_hard_floors, 1) > 0 THEN
      v_reason := format('Verified character floor(s) failed: %s', array_to_string(v_hard_floors, ', '));
    ELSE
      v_reason := format('Verified decline pattern matched: %s', array_to_string(v_decline, ', '));
    END IF;
  ELSIF v_hard_hire_count > 0 THEN
    v_verdict := 'hire';
    v_reason := format('Verified hire pattern matched: %s', array_to_string(v_hire, ', '));
  ELSIF array_length(v_hire, 1) > 0 AND v_soft_decline_count = 0 THEN
    v_verdict := 'consider';
    v_reason := format('Green flag(s) with no counter-signals: %s — proceed to interview', array_to_string(v_hire, ', '));
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
    v_reason := format('Unverified decline signal(s): %s — probe in interview', array_to_string(v_decline, ', '));
  ELSIF array_length(v_consider, 1) > 0 THEN
    v_verdict := 'consider';
    v_reason := format('Coaching signals: %s', array_to_string(v_consider, ', '));
  ELSE
    v_verdict := 'consider';
    v_reason := 'No decisive rule matches — proceed to standard interview process';
  END IF;

  verdict := v_verdict; primary_reason := v_reason; character_floors_failed := v_floors;
  decline_signals := v_decline; consider_signals := v_consider; hire_signals := v_hire;
  informational_signals := v_info; matched_rules_count := v_matched_count; floor_failures_count := v_floor_count;
  RETURN NEXT;
END;
$function$;
