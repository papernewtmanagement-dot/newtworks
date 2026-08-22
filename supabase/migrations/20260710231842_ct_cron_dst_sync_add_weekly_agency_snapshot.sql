-- Extend apply_ct_cron_dst_sync() to also lock Weekly Agency Snapshot -
-- Gmail Parse to 15:30 CT year-round (3:30 PM CT Friday).
-- Previously the recipe was `30 21 * * 5` fixed-UTC anchor → fires at 3:30 PM
-- CT in winter but 4:30 PM CT in summer. Peter's original stated intent is
-- 3:30 PM CT year-round. Adding it to the DST sync makes that automatic.
--
-- DST sync cron: daily 09:00 UTC (3-4 AM CT), so any drift self-corrects
-- overnight on DST transitions.

CREATE OR REPLACE FUNCTION public.apply_ct_cron_dst_sync()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_offset_hours int;
  v_nag_cron_utc text;         -- 07:00 CT base hour ("0 12" CDT / "0 13" CST)
  v_snapshot_cron text;        -- 15:30 CT Friday full cron
BEGIN
  -- CT is behind UTC. (CT wall-clock) - (UTC wall-clock) = -5h (CDT) or -6h (CST)
  v_offset_hours := ABS(
    EXTRACT(EPOCH FROM (
      (now() AT TIME ZONE 'America/Chicago')::timestamp
      - (now() AT TIME ZONE 'UTC')::timestamp
    ))::int / 3600
  );

  IF v_offset_hours = 5 THEN
    v_nag_cron_utc  := '0 12';           -- CDT: 07:00 CT = 12:00 UTC
    v_snapshot_cron := '30 20 * * 5';    -- CDT: 15:30 CT Fri = 20:30 UTC Fri
  ELSE
    v_nag_cron_utc  := '0 13';           -- CST: 07:00 CT = 13:00 UTC
    v_snapshot_cron := '30 21 * * 5';    -- CST: 15:30 CT Fri = 21:30 UTC Fri
  END IF;

  UPDATE automation_recipes
  SET cron_expression = v_nag_cron_utc || ' * * 0-3',
      updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'payroll_weekly_nag'
    AND is_active = true;

  UPDATE automation_recipes
  SET cron_expression = v_nag_cron_utc || ' * * *',
      updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'pfa_monthly_nag'
    AND is_active = true;

  UPDATE automation_recipes
  SET cron_expression = v_snapshot_cron,
      updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Weekly Agency Snapshot - Gmail Parse'
    AND is_active = true;

  RETURN jsonb_build_object(
    'ct_offset_hours',    v_offset_hours,
    'nag_cron_utc_base',  v_nag_cron_utc,
    'snapshot_cron',      v_snapshot_cron,
    'timestamp',          now()
  );
END;
$function$;

-- Apply immediately so the recipe reflects current CT state (CDT July 2026 → 30 20 * * 5)
SELECT public.apply_ct_cron_dst_sync();
