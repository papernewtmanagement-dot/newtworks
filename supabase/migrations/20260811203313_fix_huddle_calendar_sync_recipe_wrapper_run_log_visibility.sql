CREATE OR REPLACE FUNCTION public.huddle_calendar_sync(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.huddle_calendar_sync(p_agency_id);
  -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
  RETURN v_result || jsonb_build_object(
    'records_processed', CASE WHEN v_result->>'status' = 'dispatched' THEN 1 ELSE 0 END,
    'output_summary', COALESCE(v_result->>'status', 'unknown') ||
      CASE WHEN v_result->>'action' IS NOT NULL THEN ' (' || (v_result->>'action') || ')' ELSE '' END ||
      CASE WHEN v_result->>'reason' IS NOT NULL THEN ' — ' || (v_result->>'reason') ELSE '' END
  );
END;
$function$;
