CREATE OR REPLACE FUNCTION public.statement_gl_writer_recipe(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  -- Hard 2026-01-01 floor: pre-2026 profit and loss comes from prior_year_pl, never here.
  v_result := public.statement_gl_writer(p_agency_id, NULL::uuid, DATE '2026-01-01', NULL::date, FALSE);
  -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
  RETURN v_result || jsonb_build_object(
    'records_processed',
      COALESCE((v_result->>'direct_category_matched')::int, 0)
      + COALESCE((v_result->>'rule_matched')::int, 0)
      + COALESCE((v_result->>'unclassified')::int, 0),
    'output_summary',
      COALESCE((v_result->>'total_statements_seen')::int, 0) || ' seen; ' ||
      COALESCE((v_result->>'direct_category_matched')::int, 0) || ' direct, ' ||
      COALESCE((v_result->>'rule_matched')::int, 0) || ' rule-matched, ' ||
      COALESCE((v_result->>'unclassified')::int, 0) || ' unclassified; ' ||
      COALESCE((v_result->>'skipped_already_posted')::int, 0) || ' already posted, ' ||
      COALESCE((v_result->>'errors')::int, 0) || ' error(s)'
  );
END;
$function$;
