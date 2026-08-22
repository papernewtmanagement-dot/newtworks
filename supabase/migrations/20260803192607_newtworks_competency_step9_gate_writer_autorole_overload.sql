-- Step 9 (part 1) of Newtworks competency layer rebuild.
-- apply_newtworks_v2_competency_gates_to_candidate previously required a
-- p_role_category argument, but hiring_candidates has no stored "target role"
-- column (the whole point of the new system is that best-fit role is
-- COMPUTED, not assigned upfront). This 1-arg overload determines the
-- best-fit role using the EXACT same argmax + tie-break logic as
-- assessment_best_fit_role (same fixed role order, same ROUND-to-int
-- comparison) so the persisted gate always matches whatever role
-- CandidateDetail displays as "best fit" -- then delegates to the existing
-- 2-arg version to do the actual write. Matches the p_candidate_id-only
-- calling convention of apply_newtworks_gma_to_candidate /
-- apply_newtworks_v2_sjt_to_candidate for the edge function finalize step.
CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_competency_gates_to_candidate(p_candidate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_candidate hiring_candidates;
  v_role_keys text[] := ARRAY['sales_outbound','sales_inbound','sales_in_book',
    'retention_reception','retention_escalation','retention_support','aspirant'];
  v_role_key text;
  v_score int;
  v_best_score int := NULL;
  v_best_role text := NULL;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;
  IF v_candidate.achievement_striving IS NULL THEN
    RETURN jsonb_build_object('error', 'no_trait_data', 'candidate_id', p_candidate_id);
  END IF;

  FOREACH v_role_key IN ARRAY v_role_keys LOOP
    v_score := ROUND((public._newtworks_role_fit_core(v_candidate, v_role_key)->>'fit_score')::numeric)::int;
    IF v_score IS NOT NULL AND (v_best_score IS NULL OR v_score > v_best_score) THEN
      v_best_score := v_score;
      v_best_role := v_role_key;
    END IF;
  END LOOP;

  IF v_best_role IS NULL THEN
    RETURN jsonb_build_object('error', 'no_fit_score_computed', 'candidate_id', p_candidate_id);
  END IF;

  RETURN public.apply_newtworks_v2_competency_gates_to_candidate(p_candidate_id, v_best_role);
END;
$function$;
