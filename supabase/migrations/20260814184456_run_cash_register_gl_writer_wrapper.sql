CREATE OR REPLACE FUNCTION public.run_cash_register_gl_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.cash_register_gl_writer(p_agency_id, false, DATE '2026-08-01', 90);
  RETURN jsonb_build_object(
    'ok', COALESCE((v_result->>'ok')::boolean, true),
    'records_processed', COALESCE((v_result->>'posted')::int, 0),
    'output_summary',
      COALESCE((v_result->>'posted')::int, 0) || ' cash-register row(s) posted, ' ||
      COALESCE((v_result->>'suppressed_transfer')::int, 0) || ' suppressed as transfer(s), ' ||
      COALESCE((v_result->>'classified')::int, 0) || ' classified, ' ||
      COALESCE((v_result->>'unclassified')::int, 0) || ' unclassified',
    'detail', v_result
  );
END;
$function$;
