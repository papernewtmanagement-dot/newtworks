INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Wrapup Ingest — Friday PM (CST winter supplement)',
  'CST-only companion to Weekly Wrapup Ingest — Friday PM. Cron 0,30 0 * * 6 UTC covers Fri 6:00 and 6:30 PM CT during CST winter (those fires cross into Sat UTC, need Sat DOW). is_active managed automatically by apply_ct_cron_dst_sync — matches parent.is_active AND (DST offset = 6). Never flip is_active by hand.',
  'cron',
  '0,30 0 * * 6',
  'INTERNAL',
  'dispatch_document_processor',
  '{"mode":"wrapup"}'::jsonb,
  false
);

INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows (CST winter supplement)',
  'CST-only companion to Weekly Wrapup Ingest — Fri 7 PM + Saturday windows. Cron 0 0 * * 0 UTC covers Sat 6 PM CT during CST winter (crosses into Sun UTC, needs Sun DOW). is_active managed automatically by apply_ct_cron_dst_sync — matches parent.is_active AND (DST offset = 6). Never flip is_active by hand.',
  'cron',
  '0 0 * * 0',
  'INTERNAL',
  'dispatch_document_processor',
  '{"mode":"wrapup"}'::jsonb,
  false
);

CREATE OR REPLACE FUNCTION public.apply_ct_cron_dst_sync()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_offset_hours     int;
  v_nag_cron_utc     text;
  v_snapshot_cron    text;
  v_wrapup_a_cron    text;
  v_wrapup_b_cron    text;
  v_wrapup_c_cron    text;
  v_is_cst           boolean;
  v_row_a_active     boolean;
  v_row_b_active     boolean;
BEGIN
  v_offset_hours := ABS(
    EXTRACT(EPOCH FROM (
      (now() AT TIME ZONE 'America/Chicago')::timestamp
      - (now() AT TIME ZONE 'UTC')::timestamp
    ))::int / 3600
  );
  v_is_cst := (v_offset_hours = 6);

  IF NOT v_is_cst THEN
    v_nag_cron_utc  := '0 12';
    v_snapshot_cron := '30 20 * * 5';
    v_wrapup_a_cron := '0,30 20-23 * * 5';
    v_wrapup_b_cron := '0 0,13,18,23 * * 6';
    v_wrapup_c_cron := '0 0 * * 6';
  ELSE
    v_nag_cron_utc  := '0 13';
    v_snapshot_cron := '30 21 * * 5';
    v_wrapup_a_cron := '0,30 21-23 * * 5';
    v_wrapup_b_cron := '0 1,14,19 * * 6';
    v_wrapup_c_cron := '0 1 * * 6';
  END IF;

  UPDATE automation_recipes SET cron_expression = v_nag_cron_utc || ' * * 0-3', updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND internal_handler = 'payroll_weekly_nag' AND is_active = true;

  UPDATE automation_recipes SET cron_expression = v_nag_cron_utc || ' * * *', updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND internal_handler = 'pfa_monthly_nag' AND is_active = true;

  UPDATE automation_recipes SET cron_expression = v_snapshot_cron, updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Agency Snapshot - Gmail Parse' AND is_active = true;

  UPDATE automation_recipes SET cron_expression = v_wrapup_a_cron, updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Wrapup Ingest — Friday PM';

  UPDATE automation_recipes SET cron_expression = v_wrapup_b_cron, updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows';

  UPDATE automation_recipes SET cron_expression = v_wrapup_c_cron, updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Wrapup No-Send Check — Fri 7 PM CT';

  SELECT COALESCE(is_active, false) INTO v_row_a_active FROM automation_recipes
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Wrapup Ingest — Friday PM';
  SELECT COALESCE(is_active, false) INTO v_row_b_active FROM automation_recipes
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows';

  UPDATE automation_recipes SET is_active = (v_row_a_active AND v_is_cst), updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Weekly Wrapup Ingest — Friday PM (CST winter supplement)';

  UPDATE automation_recipes SET is_active = (v_row_b_active AND v_is_cst), updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows (CST winter supplement)';

  RETURN jsonb_build_object(
    'ct_offset_hours', v_offset_hours,
    'is_cst', v_is_cst,
    'nag_cron_utc_base', v_nag_cron_utc,
    'snapshot_cron', v_snapshot_cron,
    'wrapup_a_cron', v_wrapup_a_cron,
    'wrapup_b_cron', v_wrapup_b_cron,
    'wrapup_c_cron', v_wrapup_c_cron,
    'supplement_a_active', (v_row_a_active AND v_is_cst),
    'supplement_b_active', (v_row_b_active AND v_is_cst),
    'timestamp', now()
  );
END;
$function$;

SELECT public.apply_ct_cron_dst_sync();
