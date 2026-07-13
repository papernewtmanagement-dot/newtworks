-- Restore Stephanie's true (clocked) hours on prior-week CPRs.
--
-- Peter promoted Stephanie AA→AM 2026-07-13, changing her from HOURLY $18/hr
-- to SALARY $800/wk. get_weekly_cpr_hours branched on live team.pay_type →
-- salary template (8-per-day) — overrode her actual clocked ~39h on last
-- week's CPR display.
--
-- Two-part fix:
-- 1. Correct pre-promotion snapshots to HOURLY $18 (evidence: SurePayroll
--    payroll_detail 2026-07-04 REGULAR $628.92 / 34.94h = $18.00/hr)
-- 2. Rewire get_weekly_cpr_hours to prefer snapshot pay_type + work_location
--    for the displayed week (live-team fallback preserved)

UPDATE public.team_weekly_snapshot
SET pay_type      = 'HOURLY',
    pay_rate      = 18.00,
    pay_frequency = 'weekly',
    source        = 'manual',
    taken_at      = now()
WHERE agency_id     = '126794dd-25ff-47d2-a436-724499733365'
  AND team_member_id = '7e161ee8-e490-46ce-903a-028390321407'
  AND week_ending_date < '2026-07-13';

CREATE OR REPLACE FUNCTION public.get_weekly_cpr_hours(p_agency_id uuid, p_week_ending_date date)
RETURNS TABLE(team_member_id uuid, day_idx integer, day_label text, work_date date, hours numeric, location text)
LANGUAGE sql
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
      COALESCE(s.pay_type,      t.pay_type)      AS pay_type,
      COALESCE(s.work_location, t.work_location) AS work_location
    FROM public.get_expected_teammates(p_agency_id, 'compensation', (p_week_ending_date - 6)) et
    JOIN public.team t ON t.id = et.team_id
    LEFT JOIN public.team_weekly_snapshot s
      ON s.agency_id       = p_agency_id
     AND s.team_member_id  = et.team_id
     AND s.week_ending_date = p_week_ending_date
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
  )
SELECT
  at.team_id AS team_member_id,
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
  ON hh.team_member_id = at.team_id
 AND hh.work_date      = wd.work_date
LEFT JOIN hourly_locations hl
  ON hl.team_member_id = at.team_id
 AND hl.work_date      = wd.work_date
LEFT JOIN time_off_per_day toff
  ON toff.team_member_id = at.team_id
 AND toff.work_date      = wd.work_date
ORDER BY at.team_id, wd.day_idx;
$function$;
