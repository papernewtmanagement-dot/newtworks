-- RE-APPLY. Migration 20260909161851 added the salaried override read; migration
-- 20260909162414 (revert_time_off_hours_cpr_shows_pto_only, a concurrent session)
-- replaced this function from a source snapshot taken before that and dropped the
-- override read as collateral. This rebuilds the override read on top of THAT
-- version, so the time_off_hours removal stands and is not undone here.
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
  -- Explicit per-day worked hours for a SALARIED teammate, entered by an admin.
  -- Wins over the assumed 8-hour day. Never applied to an HOURLY teammate: their
  -- hours come from the time clock, which is also what Retention Points pay reads.
  salaried_overrides AS (
    SELECT team_member_id, work_date, hours
    FROM public.salaried_hours_overrides
    WHERE agency_id = p_agency_id
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
    -- an entered figure beats the assumption; otherwise assume 8 less time off
    WHEN so.hours IS NOT NULL THEN so.hours
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
LEFT JOIN salaried_overrides so
  ON so.team_member_id = at.team_id
 AND so.work_date      = wd.work_date
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
