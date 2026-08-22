CREATE OR REPLACE FUNCTION public.run_ledger_dup_pass(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result record;
BEGIN
  SELECT * INTO v_result FROM public.raise_ledger_dup_candidate_alerts(p_agency_id);
  RETURN jsonb_build_object(
    'ok', true,
    'candidates_found', v_result.candidates_found,
    'alerts_raised', v_result.alerts_raised,
    -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
    'records_processed', COALESCE(v_result.alerts_raised, 0),
    'output_summary', COALESCE(v_result.candidates_found, 0) || ' duplicate candidate(s) found, ' ||
      COALESCE(v_result.alerts_raised, 0) || ' new alert(s) raised'
  );
END;
$function$;
