
-- Wrapper for automation_recipes dispatcher (signature: uuid, uuid -> jsonb)
-- Companion to raise_ledger_dup_candidate_alerts. See prior migration
-- ledger_dup_detection_credit_dedup_and_alert_pass.
CREATE OR REPLACE FUNCTION public.run_ledger_dup_pass(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_result record;
BEGIN
  SELECT * INTO v_result FROM public.raise_ledger_dup_candidate_alerts(p_agency_id);
  RETURN jsonb_build_object(
    'ok', true,
    'candidates_found', v_result.candidates_found,
    'alerts_raised', v_result.alerts_raised
  );
END;
$function$;

COMMENT ON FUNCTION public.run_ledger_dup_pass(uuid, uuid) IS
  'automation_recipes wrapper for raise_ledger_dup_candidate_alerts. Returns jsonb with candidates_found + alerts_raised.';

