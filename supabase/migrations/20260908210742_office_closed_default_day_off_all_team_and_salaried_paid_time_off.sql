-- Office closed = default day off for the whole team, and paid time off now shows
-- for salaried members on the CPR too.
--
-- DESIGN RECORD (2026-09-08, Peter ruling).
--
-- PETER'S RULE, verbatim intent: "when the office is closed, it becomes a default
-- day off for everyone unless we change that manually." Everyone, not a role.
--
-- WHAT WAS WRONG: materialize_holiday_time_off_for_account_associates gated on
-- role_level = 'Account Associate' AND employment_type = 'Full Time'. Labor Day
-- 2026-09-07 therefore produced a paid day off for Cassandra Alves (Account
-- Associate) and nothing for Thomas Lynch (Unit Manager), Stephanie Rogers
-- (Account Manager) or Peter (Owner). The CPR showed Thomas working a full 8-hour
-- day and Stephanie a half day on a day the office was shut.
--
-- WHAT CHANGED:
--   1. Renamed to materialize_holiday_time_off_for_team. The old name asserted a
--      scope that is no longer true and would mislead the next reader.
--   2. role_level gate removed entirely. Every active, non-admin/backoffice member
--      gets the day off record. Owner included — the office being closed applies to
--      him as much as anyone.
--   3. employment_type no longer gates WHETHER a record is created, only whether it
--      is PAID: is_paid = (employment_type = 'Full Time'). This keeps the handbook's
--      paid-holiday benefit scope intact while still recording the closure for
--      everyone. Every active member is Full Time as of today, so nothing is
--      currently unpaid by this branch.
--   4. is_admin_backoffice members stay excluded. That exclusion predates this
--      change and was deliberate; Peter's ruling was about the agency team.
--   5. Note text rewritten — it claimed "Paid holiday for full-time Account
--      Associates per handbook Hours & Time Off," which is now false.
--
-- STILL FORWARD-LOOKING by default so a routine run never invents a past paid day.
-- Pass p_from_date explicitly to backfill a specific closure.
--
-- ALSO FIXED HERE: get_weekly_cpr_hours.paid_time_off_hours was scoped to HOURLY
-- only, on the stated reasoning that salaried members "already carry their paid day
-- inside hours." That reasoning was wrong. The salaried branch computes
-- 8 - hours_off, which REMOVES the paid day rather than carrying it, so a salaried
-- paid closure rendered as a zero day with nothing to explain it. Now that a closure
-- is a team-wide default this would misreport every holiday week for every salaried
-- person. paid_time_off_hours now applies to salaried as well, and the two figures
-- still sum correctly: full paid day = 0 worked + 8 paid; paid half day = 4 worked
-- + 4 paid; unpaid day = 0 + 0.
--
-- OVERTIME NOTE (unchanged, do not "fix" later): paid time off is NOT hours worked
-- and never counts toward the 40-hour overtime threshold under the federal Fair
-- Labor Standards Act (29 CFR 778.218). paid_time_off_hours is a pay-visibility
-- figure only.

CREATE OR REPLACE FUNCTION public.materialize_holiday_time_off_for_team(p_agency_id uuid, p_from_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_from       date := COALESCE(p_from_date, (now() AT TIME ZONE 'America/Chicago')::date);
  v_created    int := 0;
  v_skipped    int := 0;
  v_row        record;
BEGIN
  FOR v_row IN
    SELECT t.id AS team_member_id, t.first_name, h.id AS holiday_id,
           h.holiday_date, h.holiday_name,
           (t.employment_type = 'Full Time') AS is_paid_holiday
    FROM public.team t
    CROSS JOIN public.company_holidays h
    WHERE t.agency_id = p_agency_id
      AND t.is_active
      AND t.archived_at IS NULL
      -- admin/backoffice sit outside the agency team roster (pre-existing carve-out)
      AND COALESCE(t.is_admin_backoffice, false) = false
      AND h.agency_id = p_agency_id
      AND h.is_active
      AND h.observance = 'closed'
      -- "if it falls on a normal working day" — Mon-Fri only
      AND EXTRACT(isodow FROM h.holiday_date) BETWEEN 1 AND 5
      -- forward-looking unless a backfill date is passed in
      AND h.holiday_date >= v_from
      -- "employed during these days"
      AND (t.hire_date IS NULL OR h.holiday_date >= t.hire_date)
  LOOP
    BEGIN
      INSERT INTO public.time_off_requests (
        agency_id, requester_team_id, request_type, start_date, end_date, partial_day,
        notes, status, is_paid, is_planned, submitted_at, decided_at, decision_note,
        derived_from_holiday_id,
        -- suppress the per-person notification email and the personal Google
        -- Calendar event: an agency-wide closure is not a personal time-off event.
        decision_notified_at, calendar_dispatched_at
      ) VALUES (
        p_agency_id, v_row.team_member_id, 'time_off_full_day',
        v_row.holiday_date, v_row.holiday_date, 'none',
        'Agency closed for ' || v_row.holiday_name
          || '. A closed day is a default day off for everyone unless it is changed manually. '
          || CASE WHEN v_row.is_paid_holiday
                  THEN 'Paid, and in addition to accrued time off — does not count against balance.'
                  ELSE 'Unpaid — the paid holiday benefit covers full-time team members.'
             END,
        'approved', v_row.is_paid_holiday, true, now(), now(),
        'Auto-approved: office closed', v_row.holiday_id,
        now(), now()
      );
      v_created := v_created + 1;
    EXCEPTION WHEN unique_violation THEN
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object('from_date', v_from, 'created', v_created, 'skipped_existing', v_skipped);
END $function$;

GRANT EXECUTE ON FUNCTION public.materialize_holiday_time_off_for_team(uuid, date) TO service_role;

-- Repoint the seeder runner at the renamed function.
CREATE OR REPLACE FUNCTION public.seed_company_holidays_runner(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_year int := EXTRACT(year FROM (now() AT TIME ZONE 'America/Chicago'))::int;
  v_this jsonb;
  v_next jsonb;
  v_off  jsonb;
  v_total int;
BEGIN
  v_this := public.seed_company_holidays(p_agency_id, v_year);
  v_next := public.seed_company_holidays(p_agency_id, v_year + 1);
  v_off  := public.materialize_holiday_time_off_for_team(p_agency_id);

  v_total := (v_this->>'inserted')::int + (v_this->>'updated')::int
           + (v_next->>'inserted')::int + (v_next->>'updated')::int
           + (v_off->>'created')::int;

  RETURN jsonb_build_object(
    'records_processed', v_total,
    'output_summary', format(
      'Holidays: %s new / %s refreshed for %s, %s new / %s refreshed for %s. Office-closed days off: %s created, %s already existed.',
      v_this->>'inserted', v_this->>'updated', v_year,
      v_next->>'inserted', v_next->>'updated', v_year + 1,
      v_off->>'created', v_off->>'skipped_existing'),
    'this_year', v_this,
    'next_year', v_next,
    'office_closed_days_off', v_off
  );
END $function$;

DROP FUNCTION IF EXISTS public.materialize_holiday_time_off_for_account_associates(uuid, date);

-- paid_time_off_hours now applies to salaried members as well as hourly.
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
