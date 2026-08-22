-- =============================================================
-- CPR Saturday-send polish migration (2026-06-20)
--   1) Fix get_weekly_cpr_hours to apply the CPR snapshot policy
--      (members archived after Sunday still count for the week).
--   2) Add auto_new / auto_lost / fire_new / fire_lost columns
--      to weekly_cpr_reports (parallel to retention block).
--   3) Flip personal-checklist boolean defaults from TRUE -> NULL
--      so new weeks load unchecked instead of pre-ticked.
-- =============================================================

-- 1. SNAPSHOT-POLICY FIX on get_weekly_cpr_hours
CREATE OR REPLACE FUNCTION public.get_weekly_cpr_hours(
  p_agency_id uuid,
  p_week_ending_date date
)
RETURNS TABLE(
  team_member_id uuid,
  day_idx integer,
  day_label text,
  work_date date,
  hours numeric,
  location text
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
WITH
  week_days AS (
    SELECT
      day_offset                                              AS day_idx,
      CASE day_offset WHEN 1 THEN 'mon' WHEN 2 THEN 'tue' WHEN 3 THEN 'wed'
                      WHEN 4 THEN 'thu' WHEN 5 THEN 'fri' END AS day_label,
      (p_week_ending_date - (6 - day_offset))::date           AS work_date
    FROM generate_series(1, 5) AS day_offset
  ),
  active_team AS (
    SELECT id AS team_member_id, pay_type, work_location
    FROM public.team
    WHERE agency_id = p_agency_id
      AND category = 'agency'
      AND COALESCE(role_level, '') <> 'Owner'
      -- Snapshot policy: count anyone who was on the team Sunday morning.
      -- Mirrors the rule used by weekly_cpr_compute_outcome and compose_weekly_cpr_html.
      AND (archived_at IS NULL
           OR archived_at > ((p_week_ending_date - 6))::timestamptz)
  ),
  hourly_hours AS (
    SELECT
      team_member_id,
      DATE(clock_in_at AT TIME ZONE 'America/Chicago') AS work_date,
      ROUND(SUM(EXTRACT(EPOCH FROM (clock_out_at - clock_in_at))) / 3600.0, 2)::numeric AS hours
    FROM public.time_clock_entries
    WHERE agency_id    = p_agency_id
      AND clock_out_at IS NOT NULL
    GROUP BY team_member_id, DATE(clock_in_at AT TIME ZONE 'America/Chicago')
  ),
  hourly_locations AS (
    SELECT team_member_id, work_date, location
    FROM (
      SELECT
        team_member_id,
        DATE(clock_in_at AT TIME ZONE 'America/Chicago') AS work_date,
        work_location AS location,
        ROW_NUMBER() OVER (
          PARTITION BY team_member_id, DATE(clock_in_at AT TIME ZONE 'America/Chicago')
          ORDER BY clock_in_at DESC
        ) AS rn
      FROM public.time_clock_entries
      WHERE agency_id     = p_agency_id
        AND work_location IS NOT NULL
    ) s
    WHERE rn = 1
  ),
  time_off_per_day AS (
    SELECT
      tor.requester_team_id AS team_member_id,
      d::date AS work_date,
      MAX(CASE
        WHEN tor.request_type = 'pto_full_day'
          OR (tor.request_type = 'sick' AND COALESCE(tor.partial_day, 'none') = 'none')
          THEN 8
        WHEN tor.request_type = 'pto_half_day'
          OR (tor.request_type = 'sick' AND tor.partial_day IN ('morning', 'afternoon'))
          THEN 4
        ELSE 0
      END) AS hours_off
    FROM public.time_off_requests tor
    CROSS JOIN LATERAL generate_series(tor.start_date, tor.end_date, '1 day'::interval) AS d
    WHERE tor.agency_id = p_agency_id
      AND tor.status    = 'approved'
    GROUP BY tor.requester_team_id, d::date
  )
SELECT
  at.team_member_id,
  wd.day_idx,
  wd.day_label,
  wd.work_date,
  CASE
    WHEN at.pay_type = 'HOURLY' THEN COALESCE(hh.hours, 0)
    ELSE GREATEST(0, 8 - COALESCE(toff.hours_off, 0))
  END AS hours,
  CASE
    WHEN at.pay_type = 'HOURLY' THEN COALESCE(hl.location, at.work_location)
    ELSE at.work_location
  END AS location
FROM active_team at
CROSS JOIN week_days wd
LEFT JOIN hourly_hours hh
  ON hh.team_member_id = at.team_member_id
 AND hh.work_date      = wd.work_date
LEFT JOIN hourly_locations hl
  ON hl.team_member_id = at.team_member_id
 AND hl.work_date      = wd.work_date
LEFT JOIN time_off_per_day toff
  ON toff.team_member_id = at.team_member_id
 AND toff.work_date      = wd.work_date
ORDER BY at.team_member_id, wd.day_idx;
$function$;

-- 2. ADD Auto/Fire New & Lost columns to the report
ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS auto_new  integer,
  ADD COLUMN IF NOT EXISTS auto_lost integer,
  ADD COLUMN IF NOT EXISTS fire_new  integer,
  ADD COLUMN IF NOT EXISTS fire_lost integer;

-- 3. FLIP defaults: personal-checklist booleans default NULL (unchecked)
ALTER TABLE public.weekly_cpr_team_detail
  ALTER COLUMN cpr_reply_done DROP DEFAULT,
  ALTER COLUMN wrapup_done    DROP DEFAULT,
  ALTER COLUMN inbox_done     DROP DEFAULT;

-- Defensive: also drop the legacy true defaults on the deprecated
-- team-checklist booleans on the detail table. They are no longer read
-- (team checklist now lives on weekly_cpr_reports), but leaving them
-- defaulted true risks confusing future debugging.
ALTER TABLE public.weekly_cpr_team_detail
  ALTER COLUMN shareds_done       DROP DEFAULT,
  ALTER COLUMN texts_done         DROP DEFAULT,
  ALTER COLUMN deposits_done      DROP DEFAULT,
  ALTER COLUMN appts_done         DROP DEFAULT,
  ALTER COLUMN tasks_done         DROP DEFAULT,
  ALTER COLUMN cases_done         DROP DEFAULT,
  ALTER COLUMN no_fu_task_done    DROP DEFAULT,
  ALTER COLUMN new_opps_done      DROP DEFAULT,
  ALTER COLUMN no_onboarding_done DROP DEFAULT,
  ALTER COLUMN no_phone_done      DROP DEFAULT,
  ALTER COLUMN bad_data_done      DROP DEFAULT;
