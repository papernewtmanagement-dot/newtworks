-- Adds explicit verdict_impact column to hiregauge_rules, populates it per strict verification
-- (hard_decline / hard_hire require n_count>=2 AND real_world_validated=true), enforces via CHECK,
-- and refactors composite function to trust the column instead of string-matching recommendation text.

-- 1. Add column
ALTER TABLE public.hiregauge_rules 
  ADD COLUMN IF NOT EXISTS verdict_impact TEXT;

COMMENT ON COLUMN public.hiregauge_rules.verdict_impact IS
  'Explicit verdict routing: hard_decline (n>=2+RWV forces decline), soft_decline (flag), consider (coaching), soft_hire (green flag), hard_hire (n>=2+RWV forces hire), informational (no verdict effect). Composite reads this column, not recommendation text.';

-- 2. Populate per rule
UPDATE public.hiregauge_rules SET verdict_impact = CASE
  WHEN rule_type = 'character_floor' AND n_count >= 2 AND real_world_validated = true THEN 'hard_decline'
  WHEN rule_type = 'character_floor' THEN 'soft_decline'
  WHEN rule_type = 'archetype' AND short_label = 'Duty-Guarded' THEN 'soft_hire'
  WHEN rule_type = 'archetype' AND n_count >= 2 AND real_world_validated = true
       AND (recommendation ILIKE 'DECLINE%' OR recommendation ILIKE 'decline%') THEN 'hard_decline'
  WHEN rule_type = 'archetype' AND (recommendation ILIKE 'DECLINE%' OR recommendation ILIKE 'decline%') THEN 'soft_decline'
  WHEN rule_type = 'archetype' AND recommendation ILIKE 'CONSIDER%' THEN 'consider'
  WHEN rule_type = 'archetype' THEN 'consider'
  WHEN rule_type = 'exit_mode' AND n_count >= 2 AND real_world_validated = true THEN 'hard_decline'
  WHEN rule_type = 'exit_mode' THEN 'soft_decline'
  WHEN rule_type = 'filter_rule' AND real_world_validated = false THEN 'informational'
  WHEN rule_type = 'filter_rule' AND n_count >= 2 AND real_world_validated = true THEN 'hard_decline'
  WHEN rule_type = 'filter_rule' AND real_world_validated = true THEN 'soft_decline'
  WHEN rule_type = 'filter_rule' THEN 'informational'
  WHEN rule_type = 'validity_rule' AND short_label = 'Validity-Dist' AND n_count >= 2 THEN 'hard_decline'
  WHEN rule_type = 'validity_rule' AND short_label = 'Validity-Dist' THEN 'soft_decline'
  WHEN rule_type = 'validity_rule' THEN 'informational'
  WHEN rule_type IN ('coaching_variant', 'strategic_seat_pattern') THEN 'consider'
  ELSE 'informational'
END
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 3. CHECK constraints
ALTER TABLE public.hiregauge_rules 
  DROP CONSTRAINT IF EXISTS hiregauge_rules_verdict_impact_valid;
ALTER TABLE public.hiregauge_rules 
  ADD CONSTRAINT hiregauge_rules_verdict_impact_valid CHECK (
    verdict_impact IS NULL OR
    verdict_impact IN ('hard_decline', 'soft_decline', 'consider', 'soft_hire', 'hard_hire', 'informational')
  );

ALTER TABLE public.hiregauge_rules
  DROP CONSTRAINT IF EXISTS hiregauge_rules_hard_impact_needs_verification;
ALTER TABLE public.hiregauge_rules
  ADD CONSTRAINT hiregauge_rules_hard_impact_needs_verification CHECK (
    verdict_impact NOT IN ('hard_decline', 'hard_hire') 
    OR (n_count >= 2 AND real_world_validated = true)
  );

-- 4. Initial composite rewrite (superseded by later migrations today — see 20260714010332 for final)
DROP FUNCTION IF EXISTS public.hiregauge_composite_recommendation(uuid);

CREATE OR REPLACE FUNCTION public.hiregauge_composite_recommendation(p_assessment_id uuid)
RETURNS TABLE(
  verdict text, primary_reason text, character_floors_failed text[],
  decline_signals text[], consider_signals text[], hire_signals text[],
  informational_signals text[], matched_rules_count integer, floor_failures_count integer
)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_row RECORD; v_impact TEXT; v_agency UUID;
  v_floors TEXT[] := ARRAY[]::TEXT[]; v_decline TEXT[] := ARRAY[]::TEXT[];
  v_consider TEXT[] := ARRAY[]::TEXT[]; v_hire TEXT[] := ARRAY[]::TEXT[];
  v_info TEXT[] := ARRAY[]::TEXT[];
  v_hard_decline_count INT := 0; v_hard_hire_count INT := 0;
  v_matched_count INT := 0; v_floor_count INT := 0;
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
      IF v_impact = 'hard_decline' THEN v_hard_decline_count := v_hard_decline_count + 1;
      ELSE v_decline := v_decline || (COALESCE(v_row.out_short_label, v_row.out_rule_name) || ' (unverified)'); END IF;
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
  IF v_hard_decline_count > 0 THEN v_verdict := 'decline'; v_reason := format('Verified character floor(s) failed: %s', array_to_string(v_floors, ', '));
  ELSIF v_hard_hire_count > 0 THEN v_verdict := 'hire'; v_reason := format('Verified hire pattern matched: %s', array_to_string(v_hire, ', '));
  ELSE v_verdict := 'consider'; v_reason := 'Superseded by later migration'; END IF;
  verdict := v_verdict; primary_reason := v_reason; character_floors_failed := v_floors;
  decline_signals := v_decline; consider_signals := v_consider; hire_signals := v_hire;
  informational_signals := v_info; matched_rules_count := v_matched_count; floor_failures_count := v_floor_count;
  RETURN NEXT;
END;
$function$;
