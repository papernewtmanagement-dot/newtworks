-- After the register posts its rows, refine any Amazon lines using the order list.
CREATE OR REPLACE FUNCTION public.run_cash_register_gl_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
  v_amz_moved int := 0;
BEGIN
  v_result := public.cash_register_gl_writer(p_agency_id, false, DATE '2026-08-01', 90);

  -- Recode Amazon charges by what was actually bought, using amazon_orders /
  -- amazon_order_items. Never reaches back before 2026-08-01.
  BEGIN
    SELECT count(*) INTO v_amz_moved
    FROM public.amazon_apply_charge_categories(p_agency_id, DATE '2026-08-01', false)
    WHERE note LIKE 'moved%';
  EXCEPTION WHEN OTHERS THEN
    v_amz_moved := -1;  -- surfaces in output_summary instead of failing the whole run
  END;

  RETURN jsonb_build_object(
    'ok', COALESCE((v_result->>'ok')::boolean, true),
    'records_processed', COALESCE((v_result->>'posted')::int, 0),
    'output_summary',
      COALESCE((v_result->>'posted')::int, 0) || ' cash-register row(s) posted, ' ||
      COALESCE((v_result->>'suppressed_transfer')::int, 0) || ' suppressed as transfer(s), ' ||
      COALESCE((v_result->>'classified')::int, 0) || ' classified, ' ||
      COALESCE((v_result->>'unclassified')::int, 0) || ' unclassified, ' ||
      CASE WHEN v_amz_moved < 0 THEN 'Amazon order match errored'
           ELSE v_amz_moved || ' Amazon line(s) recoded from the order list' END,
    'detail', v_result || jsonb_build_object('amazon_lines_recoded', v_amz_moved)
  );
END;
$function$;
