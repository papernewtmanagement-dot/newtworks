CREATE OR REPLACE FUNCTION public.monthly_close_generator(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_cfg          jsonb;
  v_today        DATE := CURRENT_DATE;
  v_target_year  INTEGER;
  v_target_month INTEGER;
  v_first        DATE;   -- first day of the month AFTER the target period (offset base)
  v_skip_exists  BOOLEAN;
  v_generate_for TEXT;
  v_item         jsonb;
  v_created      INTEGER := 0;
  v_offset       INTEGER;
  v_expected     DATE;
  v_brnote       TEXT;
BEGIN
  SELECT input_config INTO v_cfg
  FROM public.automation_recipes WHERE id = p_recipe_id;
  IF v_cfg IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'no input_config; nothing generated');
  END IF;

  v_skip_exists  := COALESCE((v_cfg->>'skip_if_exists')::boolean, true);
  v_generate_for := COALESCE(v_cfg->>'generate_for', 'previous_month');

  -- Target period = the month we are closing. Default: the previous month
  -- relative to today (recipe fires on the 1st).
  IF v_generate_for = 'current_month' THEN
    v_target_year  := EXTRACT(YEAR FROM v_today)::INT;
    v_target_month := EXTRACT(MONTH FROM v_today)::INT;
  ELSE
    v_target_year  := EXTRACT(YEAR FROM (v_today - INTERVAL '1 month'))::INT;
    v_target_month := EXTRACT(MONTH FROM (v_today - INTERVAL '1 month'))::INT;
  END IF;

  -- expected_by offsets are measured from the 1st of the month AFTER the
  -- target period (i.e. when documents for the closed month start arriving).
  v_first := (make_date(v_target_year, v_target_month, 1) + INTERVAL '1 month')::date;

  IF v_skip_exists AND EXISTS (
      SELECT 1 FROM public.monthly_close_checklist
      WHERE agency_id = p_agency_id
        AND period_year = v_target_year AND period_month = v_target_month) THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('checklist for %s-%s already exists; skipped', v_target_year, v_target_month));
  END IF;

  -- Standard items
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(v_cfg->'items','[]'::jsonb))
  LOOP
    v_offset := COALESCE((v_item->>'expected_offset_days')::int, 5);
    v_expected := v_first + v_offset;
    INSERT INTO public.monthly_close_checklist
      (agency_id, period_year, period_month, doc_category, doc_label,
       expected_by, received_at, document_id, status, is_closed, notes, created_at)
    VALUES
      (p_agency_id, v_target_year, v_target_month,
       v_item->>'doc_category',
       (v_item->>'doc_label') ||
         CASE WHEN v_item ? 'account_code' THEN '' ELSE '' END,
       v_expected, NULL, NULL, 'pending', false,
       NULLIF(v_item->>'account_code',''), NOW());
    v_created := v_created + 1;
  END LOOP;

  -- Balance-review items (carry-forward accounts pending CPA adjustment)
  v_brnote := v_cfg->>'balance_review_note';
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(v_cfg->'balance_review_items','[]'::jsonb))
  LOOP
    v_offset := COALESCE((v_item->>'expected_offset_days')::int, 10);
    v_expected := v_first + v_offset;
    INSERT INTO public.monthly_close_checklist
      (agency_id, period_year, period_month, doc_category, doc_label,
       expected_by, received_at, document_id, status, is_closed, notes, created_at)
    VALUES
      (p_agency_id, v_target_year, v_target_month,
       v_item->>'doc_category',
       v_item->>'doc_label',
       v_expected, NULL, NULL, 'pending', false,
       v_brnote, NOW());
    v_created := v_created + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'records_processed', v_created,
    'output_summary', format('%s checklist items generated for %s-%s', v_created, v_target_year, v_target_month));
END;
$function$;
