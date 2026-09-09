-- Revert time_off_hours: the CPR column shows PTO only, never unpaid time off.
--
-- DESIGN RECORD (2026-09-09, Peter ruling): "For the time off column on the CPR, the
-- title should be PTO. Do not include unpaid time off. Unpaid would be any hours not
-- mentioned obviously."
--
-- time_off_hours was added earlier (migration 20260909145114) to feed a "Time Off"
-- total covering paid AND unpaid absence. Peter ruled against surfacing unpaid at all,
-- so the column is REMOVED rather than left unused — an unwired column named
-- time_off_hours is exactly the thing a future session would helpfully plug back into
-- the PTO total and break the ruling.
--
-- HOW UNPAID READS INSTEAD, per Peter: it does not read. Unpaid absence is simply
-- hours that never appear. The worked figure is lower and nothing is added to PTO.
-- Do NOT reintroduce an unpaid figure, an unpaid marker, or an "all time off" total.
--
-- get_weekly_cpr_hours is back to: hours (worked), paid_time_off_hours (PTO), location.
--
-- RETENTION SPLIT UNAFFECTED, and must stay that way: compute_weekly_retention_points
-- reads ONLY hours, and only where location = 'in_office'. paid_time_off_hours is read
-- by nothing else in the database. Never add it to that function or any pay-split input.
--
-- OVERTIME NOTE (unchanged): paid time off is not hours worked and never counts toward
-- the 40-hour overtime line (29 CFR 778.218).

DROP FUNCTION IF EXISTS public.get_weekly_cpr_hours(uuid, date);

CREATE OR REPLACE FUNCTION public.get_weekly_cpr_hours(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, day_idx integer, day_label text, work_date date, hours numeric, paid_time_off_hours numeric, location text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
    SELECT
      et.team_id,
      COALESCE(d.pay_type,      t.pay_type)      AS pay_type,
      COALESCE(d.work_location, t.work_location) AS work_location,
      COALESCE(t.start_date, d.start_date)       AS start_date,
      COALESCE(t.end_date,   d.end_date)         AS end_date
    FROM public.get_expected_teammates(p_agency_id, 'compensation', (p_week_ending_date - 6)) et
    JOIN public.team t ON t.id = et.team_id
    LEFT JOIN public.weekly_cpr_reports r
      ON r.agency_id = p_agency_id AND r.week_ending_date = p_week_ending_date
    LEFT JOIN public.weekly_cpr_team_detail d
      ON d.weekly_cpr_report_id = r.id AND d.team_member_id = et.team_id
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
        WHEN tor.request_type = 'time_off_full_day'
          OR (tor.request_type = 'sick' AND COALESCE(tor.partial_day, 'none') = 'none')
          THEN 8
        WHEN tor.request_type = 'time_off_half_day'
          OR (tor.request_type = 'sick' AND tor.partial_day IN ('morning', 'afternoon'))
          THEN 4
        ELSE 0
      END) AS hours_off
    FROM public.time_off_requests tor
    CROSS JOIN LATERAL generate_series(tor.start_date, tor.end_date, '1 day'::interval) AS d
    WHERE tor.agency_id = p_agency_id
      AND tor.status    = 'approved'
    GROUP BY tor.requester_team_id, d::date
  ),
  -- PAID time off only. Same day-length mapping as time_off_per_day, but gated on
  -- is_paid so an unpaid day stays at zero. Remote day types are excluded because
  -- they are worked days, not time off.
  paid_time_off_per_day AS (
    SELECT
      tor.requester_team_id AS team_member_id,
      d::date AS work_date,
      MAX(CASE
        WHEN tor.request_type = 'time_off_full_day'
          OR (tor.request_type = 'sick' AND COALESCE(tor.partial_day, 'none') = 'none')
          THEN 8
        WHEN tor.request_type = 'time_off_half_day'
          OR (tor.request_type = 'sick' AND tor.partial_day IN ('morning', 'afternoon'))
          THEN 4
        ELSE 0
      END) AS paid_hours_off
    FROM public.time_off_requests tor
    CROSS JOIN LATERAL generate_series(tor.start_date, tor.end_date, '1 day'::interval) AS d
    WHERE tor.agency_id    = p_agency_id
      AND tor.status       = 'approved'
      AND tor.is_paid IS TRUE
      AND tor.request_type NOT IN ('remote_day', 'remote_half_day')
    GROUP BY tor.requester_team_id, d::date
  ),
  remote_per_day AS (
    SELECT DISTINCT
      tor.requester_team_id AS team_member_id,
      d::date               AS work_date
    FROM public.time_off_requests tor
    CROSS JOIN LATERAL generate_series(tor.start_date, tor.end_date, '1 day'::interval) AS d
    WHERE tor.agency_id    = p_agency_id
      AND tor.status       = 'approved'
      AND tor.request_type IN ('remote_day', 'remote_half_day')
  )
SELECT
  at.team_id AS team_member_id,
  wd.day_idx,
  wd.day_label,
  wd.work_date,
  CASE
    WHEN at.pay_type = 'HOURLY' THEN COALESCE(hh.hours, 0)
    -- not employed yet / already gone: no assumed day
    WHEN at.start_date IS NOT NULL AND wd.work_date < at.start_date THEN 0
    WHEN at.end_date   IS NOT NULL AND wd.work_date > at.end_date   THEN 0
    ELSE GREATEST(0, 8 - COALESCE(toff.hours_off, 0))
  END AS hours,
  CASE
    -- Applies to hourly AND salaried. The salaried `hours` branch above subtracts
    -- time off, so it removes the paid day rather than carrying it — this column is
    -- what puts it back. Worked + paid sum to the day: full paid day = 0 + 8,
    -- paid half day = 4 + 4, unpaid day = 0 + 0.
    WHEN at.start_date IS NOT NULL AND wd.work_date < at.start_date THEN 0
    WHEN at.end_date   IS NOT NULL AND wd.work_date > at.end_date   THEN 0
    ELSE COALESCE(ptoff.paid_hours_off, 0)
  END::numeric AS paid_time_off_hours,
  CASE
    WHEN at.pay_type = 'HOURLY'
      THEN COALESCE(hl.location, CASE WHEN rpd.team_member_id IS NOT NULL THEN 'remote' END, at.work_location)
    ELSE COALESCE(CASE WHEN rpd.team_member_id IS NOT NULL THEN 'remote' END, at.work_location)
  END AS location
FROM active_team at
CROSS JOIN week_days wd
LEFT JOIN hourly_hours hh
  ON hh.team_member_id = at.team_id
 AND hh.work_date      = wd.work_date
LEFT JOIN hourly_locations hl
  ON hl.team_member_id = at.team_id
 AND hl.work_date      = wd.work_date
LEFT JOIN time_off_per_day toff
  ON toff.team_member_id = at.team_id
 AND toff.work_date      = wd.work_date
LEFT JOIN paid_time_off_per_day ptoff
  ON ptoff.team_member_id = at.team_id
 AND ptoff.work_date      = wd.work_date
LEFT JOIN remote_per_day rpd
  ON rpd.team_member_id = at.team_id
 AND rpd.work_date      = wd.work_date
ORDER BY at.team_id, wd.day_idx;
$function$;

GRANT EXECUTE ON FUNCTION public.get_weekly_cpr_hours(uuid, date) TO anon, authenticated, service_role;
