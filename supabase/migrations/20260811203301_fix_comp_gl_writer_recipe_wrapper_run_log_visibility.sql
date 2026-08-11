CREATE OR REPLACE FUNCTION public.comp_gl_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.comp_gl_writer(p_agency_id, FALSE);
  -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
  RETURN v_result || jsonb_build_object(
    'records_processed', COALESCE((v_result->>'posted_revenue')::int, 0)
      + COALESCE((v_result->>'posted_deduction')::int, 0)
      + COALESCE((v_result->>'posted_pending_review')::int, 0),
    'output_summary',
      COALESCE((v_result->>'posted_revenue')::int, 0) || ' revenue, ' ||
      COALESCE((v_result->>'posted_deduction')::int, 0) || ' deduction, ' ||
      COALESCE((v_result->>'posted_pending_review')::int, 0) || ' pending-review posted; ' ||
      COALESCE((v_result->>'skipped_no_pl_effect')::int, 0) || ' skipped, ' ||
      COALESCE((v_result->>'errors')::int, 0) || ' error(s)'
  );
END;
$function$
