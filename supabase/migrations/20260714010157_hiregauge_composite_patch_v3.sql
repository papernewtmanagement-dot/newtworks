-- Patch composite: (a) skip character_floor PASS rows (passing = no signal),
-- (b) distinguish hard vs soft floors in reason string so 'Verified' only labels hard ones.
-- Superseded by 20260714010332 (final soft-never-forces-verdict logic).

CREATE OR REPLACE FUNCTION public.hiregauge_composite_recommendation(p_assessment_id uuid)
RETURNS TABLE(
  verdict text, primary_reason text, character_floors_failed text[],
  decline_signals text[], consider_signals text[], hire_signals text[],
  informational_signals text[], matched_rules_count integer, floor_failures_count integer
)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_row RECORD; v_impact TEXT; v_agency UUID;
  v_floors TEXT[] := ARRAY[]::TEXT[]; v_hard_floors TEXT[] := ARRAY[]::TEXT[]; v_soft_floors TEXT[] := ARRAY[]::TEXT[];
  v_decline TEXT[] := ARRAY[]::TEXT[]; v_consider TEXT[] := ARRAY[]::TEXT[]; v_hire TEXT[] := ARRAY[]::TEXT[]; v_info TEXT[] := ARRAY[]::TEXT[];
  v_hard_decline_count INT := 0; v_hard_hire_count INT := 0; v_matched_count INT := 0; v_floor_count INT := 0;
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
      END IF;
    ELSIF v_row.out_pass = true AND v_row.out_rule_type = 'character_floor' THEN CONTINUE;
    ELSIF v_row.out_pass = true THEN
      v_matched_count := v_matched_count + 1;
      CASE v_impact
        WHEN 'hard_decline' THEN v_decline := v_decline || COALESCE(v_row.out_short_label, v_row.out_rule_name); v_hard_decline_count := v_hard_decline_count + 1;
        WHEN 'soft_decline' THEN v_decline := v_decline || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'consider' THEN v_consider := v_consider || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'soft_hire' THEN v_hire := v_hire || COALESCE(v_row.out_short_label, v_row.out_rule_name);
        WHEN 'hard_hire' THEN v_hire := v_hire || COALESCE(v_row.out_short_label, v_row.out_rule_name); v_hard_hire_count := v_hard_hire_count + 1;
        ELSE v_info := v_info || COALESCE(v_row.out_short_label, v_row.out_rule_name);
      END CASE;
    END IF;
  END LOOP;
  -- Body simplified for repo mirror; live logic is in the successor migration.
  IF v_hard_decline_count > 0 THEN v_verdict := 'decline'; v_reason := 'See successor migration for full logic';
  ELSIF v_hard_hire_count > 0 THEN v_verdict := 'hire'; v_reason := 'See successor';
  ELSE v_verdict := 'consider'; v_reason := 'See successor'; END IF;
  verdict := v_verdict; primary_reason := v_reason; character_floors_failed := v_floors;
  decline_signals := v_decline; consider_signals := v_consider; hire_signals := v_hire;
  informational_signals := v_info; matched_rules_count := v_matched_count; floor_failures_count := v_floor_count;
  RETURN NEXT;
END;
$function$;
