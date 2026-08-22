-- Step 8 (frontend prerequisite) of Newtworks competency layer rebuild.
-- The 7 newtworks_role_fit_<role> functions take a full hiring_candidates
-- ROW as their argument (matching the internal calling convention used by
-- assessment_best_fit_role). PostgREST/frontend RPC calls need a uuid-based
-- entry point -- same pattern as assessment_best_fit_role(p_assessment_id uuid).
-- This wrapper returns the FULL gated detail (fit_score + all 12 competencies
-- with tier/floor/adjusted + gates_fired/verdict_cap/hard_decline/churn_risk)
-- for all 7 roles in one call, keyed by role_category -- same shape contract
-- as the old assessment_all_competencies orchestrator it replaces for v2.
CREATE OR REPLACE FUNCTION public.newtworks_all_role_fits(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_candidate hiring_candidates;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_candidate.achievement_striving IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object(
    'sales_outbound',       public.newtworks_role_fit_sales_outbound(v_candidate),
    'sales_inbound',        public.newtworks_role_fit_sales_inbound(v_candidate),
    'sales_in_book',        public.newtworks_role_fit_sales_in_book(v_candidate),
    'retention_reception',  public.newtworks_role_fit_retention_reception(v_candidate),
    'retention_escalation', public.newtworks_role_fit_retention_escalation(v_candidate),
    'retention_support',    public.newtworks_role_fit_retention_support(v_candidate),
    'aspirant',             public.newtworks_role_fit_aspirant(v_candidate)
  );
END;
$function$;
