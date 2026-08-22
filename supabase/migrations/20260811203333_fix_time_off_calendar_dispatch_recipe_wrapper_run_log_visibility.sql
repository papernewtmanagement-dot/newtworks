CREATE OR REPLACE FUNCTION public.time_off_calendar_dispatch(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.time_off_calendar_dispatch(p_agency_id);
  -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
  RETURN v_result || jsonb_build_object(
    'records_processed', COALESCE((v_result->>'events_created')::int, 0),
    'output_summary',
      COALESCE((v_result->>'events_created')::int, 0) || ' event(s) created, ' ||
      COALESCE((v_result->>'events_skipped')::int, 0) || ' skipped, ' ||
      COALESCE((v_result->>'event_ids_captured')::int, 0) || ' event id(s) captured'
  );
END;
$function$;
