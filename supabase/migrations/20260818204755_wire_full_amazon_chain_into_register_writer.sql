-- Full Amazon chain, run right after the cash register posts:
--   1. work out which entity each new order belongs to, from the card
--   2. categorize any new items by keyword rule
--   3. recode the Amazon ledger lines to the category the order calls for
-- Each step is wrapped so a failure reports itself instead of killing the run.
CREATE OR REPLACE FUNCTION public.run_cash_register_gl_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
DECLARE
  v_result      jsonb;
  v_entity_set  int := 0;
  v_items_coded int := 0;
  v_amz_moved   int := 0;
BEGIN
  v_result := public.cash_register_gl_writer(p_agency_id, false, DATE '2026-08-01', 90);

  BEGIN
    SELECT count(*) INTO v_entity_set
    FROM public.match_amazon_orders_to_cash_register(p_agency_id) WHERE matched;
  EXCEPTION WHEN OTHERS THEN v_entity_set := -1;
  END;

  BEGIN
    v_items_coded := public.amazon_categorize_new_items(p_agency_id);
  EXCEPTION WHEN OTHERS THEN v_items_coded := -1;
  END;

  BEGIN
    SELECT count(*) INTO v_amz_moved
    FROM public.amazon_apply_charge_categories(p_agency_id, DATE '2026-08-01', false)
    WHERE note LIKE 'moved%';
  EXCEPTION WHEN OTHERS THEN v_amz_moved := -1;
  END;

  RETURN jsonb_build_object(
    'ok', COALESCE((v_result->>'ok')::boolean, true),
    'records_processed', COALESCE((v_result->>'posted')::int, 0),
    'output_summary',
      COALESCE((v_result->>'posted')::int, 0) || ' cash-register row(s) posted, ' ||
      COALESCE((v_result->>'suppressed_transfer')::int, 0) || ' suppressed as transfer(s), ' ||
      COALESCE((v_result->>'classified')::int, 0) || ' classified, ' ||
      COALESCE((v_result->>'unclassified')::int, 0) || ' unclassified; Amazon: ' ||
      v_entity_set  || ' order(s) assigned to an entity, ' ||
      v_items_coded || ' item(s) categorized, ' ||
      v_amz_moved   || ' ledger line(s) recoded',
    'detail', v_result || jsonb_build_object(
        'amazon_orders_entity_assigned', v_entity_set,
        'amazon_items_categorized',      v_items_coded,
        'amazon_ledger_lines_recoded',   v_amz_moved)
  );
END;
$fn$;
