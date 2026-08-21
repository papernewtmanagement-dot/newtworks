CREATE OR REPLACE FUNCTION public.apply_ct_cron_dst_sync()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_offset_hours       int;
  v_nag_cron_utc       text;
  v_snapshot_cron      text;
  v_wrapup_a_cron      text;
  v_wrapup_b_cron      text;
  v_wrapup_c_cron      text;
BEGIN
  v_offset_hours := ABS(
    EXTRACT(EPOCH FROM (
      (now() AT TIME ZONE 'America/Chicago')::timestamp
      - (now() AT TIME ZONE 'UTC')::timestamp
    ))::int / 3600
  );

  IF v_offset_hours = 5 THEN
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

  UPDATE automation_recipes
  SET cron_expression = v_nag_cron_utc || ' * * 0-3', updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'payroll_weekly_nag' AND is_active = true;

  UPDATE automation_recipes
  SET cron_expression = v_nag_cron_utc || ' * * *', updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'pfa_monthly_nag' AND is_active = true;

  UPDATE automation_recipes
  SET cron_expression = v_snapshot_cron, updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Weekly Agency Snapshot - Gmail Parse' AND is_active = true;

  UPDATE automation_recipes
  SET cron_expression = v_wrapup_a_cron, updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Weekly Wrapup Ingest — Friday PM';

  UPDATE automation_recipes
  SET cron_expression = v_wrapup_b_cron, updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows';

  UPDATE automation_recipes
  SET cron_expression = v_wrapup_c_cron, updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Weekly Wrapup No-Send Check — Fri 7 PM CT';

  RETURN jsonb_build_object(
    'ct_offset_hours',    v_offset_hours,
    'nag_cron_utc_base',  v_nag_cron_utc,
    'snapshot_cron',      v_snapshot_cron,
    'wrapup_a_cron',      v_wrapup_a_cron,
    'wrapup_b_cron',      v_wrapup_b_cron,
    'wrapup_c_cron',      v_wrapup_c_cron,
    'timestamp',          now()
  );
END;
$function$;

SELECT public.apply_ct_cron_dst_sync();
