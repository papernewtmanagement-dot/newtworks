-- Extends apply_ct_cron_dst_sync to cover the three new wrap-up recipes staged
-- 2026-07-22. Per standing rule "CT-anchored cron recipes MUST register with
-- apply_ct_cron_dst_sync at creation" — no more "handle DST before winter"
-- deferrals.
--
-- Boundary handling per rule option (a) — drop boundary fires in the affected
-- DST state rather than add supplementary rows:
--   * Row A (Friday PM ingest): CDT covers 3-6:30 PM CT (8 fires); CST covers
--     3-5:30 PM CT (6 fires). Fri 6-6:30 PM CST would cross into Sat UTC —
--     dropped.
--   * Row B (Fri 7 PM + Sat windows): CDT covers Fri 7 PM + Sat 8 AM/1 PM/6 PM CT
--     (4 fires); CST covers Fri 7 PM + Sat 8 AM/1 PM CT (3 fires). Sat 6 PM CST
--     would cross into Sun UTC — dropped.
--   * Row C (No-Send Check): 1 fire in both states, cleanly expressible.
--
-- Match by recipe_name (three wrap-up recipes share dispatch_document_processor
-- internal_handler; recipe_name is the unique key). is_active gate REMOVED
-- for these three rows — they should get correct cron even while INACTIVE, so
-- that when Peter flips them active mid-year the cron is already DST-current.
-- Payroll/PFA/snapshot rows retain the is_active gate to preserve existing
-- behavior.

CREATE OR REPLACE FUNCTION public.apply_ct_cron_dst_sync()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_offset_hours       int;
  v_nag_cron_utc       text;   -- 07:00 CT base hour ("0 12" CDT / "0 13" CST)
  v_snapshot_cron      text;   -- 15:30 CT Friday full cron
  v_wrapup_a_cron      text;   -- Weekly Wrapup Ingest — Friday PM
  v_wrapup_b_cron      text;   -- Weekly Wrapup Ingest — Fri 7 PM + Saturday windows
  v_wrapup_c_cron      text;   -- Weekly Wrapup No-Send Check — Fri 7 PM CT
BEGIN
  -- CT is behind UTC. (CT wall-clock) - (UTC wall-clock) = -5h (CDT) or -6h (CST)
  v_offset_hours := ABS(
    EXTRACT(EPOCH FROM (
      (now() AT TIME ZONE 'America/Chicago')::timestamp
      - (now() AT TIME ZONE 'UTC')::timestamp
    ))::int / 3600
  );

  IF v_offset_hours = 5 THEN
    -- CDT (summer, Mar 2nd Sun – Nov 1st Sun)
    v_nag_cron_utc  := '0 12';                    -- 07:00 CT = 12:00 UTC
    v_snapshot_cron := '30 20 * * 5';             -- Fri 15:30 CT = Fri 20:30 UTC
    v_wrapup_a_cron := '0,30 20-23 * * 5';        -- Fri 3-6:30 PM CT (8 fires)
    v_wrapup_b_cron := '0 0,13,18,23 * * 6';      -- Fri 7 PM + Sat 8 AM/1 PM/6 PM CT (4 fires)
    v_wrapup_c_cron := '0 0 * * 6';               -- Fri 7 PM CT (1 fire)
  ELSE
    -- CST (winter, Nov 1st Sun – Mar 2nd Sun)
    v_nag_cron_utc  := '0 13';                    -- 07:00 CT = 13:00 UTC
    v_snapshot_cron := '30 21 * * 5';             -- Fri 15:30 CT = Fri 21:30 UTC
    v_wrapup_a_cron := '0,30 21-23 * * 5';        -- Fri 3-5:30 PM CT (6 fires; drops 6-6:30 PM CT crossing boundary)
    v_wrapup_b_cron := '0 1,14,19 * * 6';         -- Fri 7 PM + Sat 8 AM/1 PM CT (3 fires; drops Sat 6 PM CT crossing to Sun UTC)
    v_wrapup_c_cron := '0 1 * * 6';               -- Fri 7 PM CT (1 fire)
  END IF;

  -- Existing recipes
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

  -- Wrap-up recipes (added 2026-07-22). No is_active gate: keep cron DST-current
  -- even while INACTIVE so Peter's activation flip is one-touch.
  UPDATE automation_recipes
  SET cron_expression = v_wrapup_a_cron,
      updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Weekly Wrapup Ingest — Friday PM';

  UPDATE automation_recipes
  SET cron_expression = v_wrapup_b_cron,
      updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows';

  UPDATE automation_recipes
  SET cron_expression = v_wrapup_c_cron,
      updated_at = now()
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

-- Fire immediately so the 3 new recipes get DST-current cron_expression right
-- now (currently we're in CDT so no change to the strings I staged, but this
-- verifies the function runs clean).
SELECT public.apply_ct_cron_dst_sync();
