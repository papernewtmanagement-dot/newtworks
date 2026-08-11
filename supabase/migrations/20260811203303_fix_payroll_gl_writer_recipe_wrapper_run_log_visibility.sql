CREATE OR REPLACE FUNCTION public.payroll_gl_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.payroll_gl_writer(p_agency_id, FALSE, NULL::date);
  -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
  IF (v_result->>'ok')::boolean IS NOT TRUE THEN
    RETURN v_result || jsonb_build_object(
      'records_processed', 0,
      'output_summary', 'ERROR: ' || COALESCE(v_result->>'error', 'unknown failure')
    );
  END IF;
  RETURN v_result || jsonb_build_object(
    'records_processed', COALESCE((v_result->>'posted')::int, 0),
    'output_summary',
      COALESCE((v_result->>'eligible')::int, 0) || ' eligible, ' ||
      COALESCE((v_result->>'posted')::int, 0) || ' posted, ' ||
      COALESCE((v_result->>'skipped_pre_cutover')::int, 0) || ' pre-cutover skipped, ' ||
      COALESCE((v_result->>'skipped_already_has_je')::int, 0) || ' already posted, ' ||
      COALESCE((v_result->>'errors')::int, 0) || ' error(s)'
  );
END;
$function$
