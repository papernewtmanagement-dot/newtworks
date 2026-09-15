-- Payroll tab (Team module) — live week data.
-- 1. time_off_day_hours(): the ONE place the 8-hour / 4-hour day-length mapping
--    lives. get_weekly_cpr_hours carried two inline copies of it; both now call
--    this, so a change to what a half day means moves every caller together.
-- 2. get_weekly_cpr_hours(): rewritten to call the helper. Behaviour identical.
-- 3. team_payroll_week(): feeds Step 1 (hours for hourly people), Step 2 (paid
--    time off for the week) and Step 4 (bonuses off that week's CPR).

CREATE OR REPLACE FUNCTION public.time_off_day_hours(
  p_request_type text,
  p_partial_day  text
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_request_type = 'time_off_full_day' THEN 8
    WHEN p_request_type = 'time_off_half_day' THEN 4
    WHEN p_request_type = 'sick' AND COALESCE(p_partial_day, 'none') = 'none'    THEN 8
    WHEN p_request_type = 'sick' AND p_partial_day IN ('morning', 'afternoon')   THEN 4
    ELSE 0
  END::numeric;
$function$;

COMMENT ON FUNCTION public.time_off_day_hours(text, text) IS
  'How many hours one day of a time-off request is worth. A full day is 8, a half day is 4, anything else is 0. Single source for every caller — do not re-state this mapping inline anywhere.';

GRANT EXECUTE ON FUNCTION public.time_off_day_hours(text, text) TO authenticated, service_role, anon;

-- ── get_weekly_cpr_hours — same output, mapping moved to the helper ──────────
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
      MAX(public.time_off_day_hours(tor.request_type, tor.partial_day)) AS hours_off
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
      MAX(public.time_off_day_hours(tor.request_type, tor.partial_day)) AS paid_hours_off
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

-- ── team_payroll_week — everything the Payroll tab needs for one week ────────
CREATE OR REPLACE FUNCTION public.team_payroll_week(
  p_agency_id        uuid,
  p_week_ending_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_week_end   date;
  v_week_start date;
  v_report_id  uuid;
  v_hours      jsonb;
  v_time_off   jsonb;
  v_bonuses    jsonb;
BEGIN
  -- Sunday to Saturday, Central, same boundary every other week-bounded figure uses.
  v_week_end := COALESCE(
    p_week_ending_date,
    (
      SELECT d + ((6 - EXTRACT(DOW FROM d)::int) % 7)
      FROM (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS d) s
    )
  );
  v_week_start := v_week_end - 6;

  SELECT r.id INTO v_report_id
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_week_end;

  -- Step 1 · hours for anyone paid by the hour. Worked hours come from the same
  -- function the CPR reads, so the two can never disagree.
  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'name'), '[]'::jsonb) INTO v_hours
  FROM (
    SELECT jsonb_build_object(
      'team_member_id', t.id,
      'name', TRIM(t.first_name || ' ' || COALESCE(t.last_name, '')),
      'pay_rate', t.pay_rate,
      'worked_hours',        COALESCE(SUM(h.hours), 0),
      'paid_time_off_hours', COALESCE(SUM(h.paid_time_off_hours), 0),
      'overtime_hours',      GREATEST(0, COALESCE(SUM(h.hours), 0) - 40),
      'days', COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'day_label', h.day_label,
            'work_date', h.work_date,
            'hours', h.hours,
            'paid_time_off_hours', h.paid_time_off_hours,
            'location', h.location
          ) ORDER BY h.day_idx
        ) FILTER (WHERE h.day_idx IS NOT NULL),
        '[]'::jsonb
      )
    ) AS x
    FROM public.team t
    LEFT JOIN public.get_weekly_cpr_hours(p_agency_id, v_week_end) h
      ON h.team_member_id = t.id
    WHERE t.agency_id = p_agency_id
      AND t.is_active
      AND t.pay_type = 'HOURLY'
    GROUP BY t.id, t.first_name, t.last_name, t.pay_rate
  ) s;

  -- Step 2 · every individual paid day off that lands in this week. Read straight
  -- off the requests so back-office people who sit outside the CPR still show.
  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'work_date', x->>'name'), '[]'::jsonb) INTO v_time_off
  FROM (
    SELECT jsonb_build_object(
      'team_member_id', t.id,
      'name', TRIM(t.first_name || ' ' || COALESCE(t.last_name, '')),
      'work_date', d::date,
      'label', public.time_off_display_label(tor.request_type, tor.is_paid),
      'partial_day', tor.partial_day,
      'hours', public.time_off_day_hours(tor.request_type, tor.partial_day),
      'notes', tor.notes
    ) AS x
    FROM public.time_off_requests tor
    JOIN public.team t ON t.id = tor.requester_team_id
    CROSS JOIN LATERAL generate_series(tor.start_date, tor.end_date, '1 day'::interval) AS d
    WHERE tor.agency_id = p_agency_id
      AND tor.status    = 'approved'
      AND tor.is_paid IS TRUE
      AND tor.request_type NOT IN ('remote_day', 'remote_half_day')
      AND public.time_off_day_hours(tor.request_type, tor.partial_day) > 0
      AND d::date BETWEEN v_week_start AND v_week_end
  ) s;

  -- Step 4 · bonuses due, straight off this week's CPR, in payroll-code order.
  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'name'), '[]'::jsonb) INTO v_bonuses
  FROM (
    SELECT jsonb_build_object(
      'team_member_id', d.team_member_id,
      'name', TRIM(COALESCE(d.first_name, '') || ' ' || COALESCE(d.last_name, '')),
      'total', (
        COALESCE(d.base_advance, 0) + COALESCE(d.health_bonus, 0)
        + COALESCE(d.service_surge_share, 0) + COALESCE(d.true_pay_bonus, 0)
        + COALESCE(d.manager_bonus, 0) + COALESCE(d.agency_profit_share, 0)
        + COALESCE(d.goals_bonus, 0) + COALESCE(d.retention_points_pay, 0)
      ),
      'lines', (
        SELECT COALESCE(jsonb_agg(j.l ORDER BY j.l->>'sort'), '[]'::jsonb)
        FROM (
          VALUES
            ('1', '0Advnce', 'Advance',                      d.base_advance),
            ('2', '1Health', 'Health',                       d.health_bonus),
            ('3', '2Serve',  'Service Surge',                d.service_surge_share),
            ('4', '3True',   'True Pay',                     d.true_pay_bonus),
            ('5', '4Manage', 'Manager',                      d.manager_bonus),
            ('6', '5Goals',  'Goals/Profit (Agency Profit)', d.agency_profit_share),
            ('7', NULL,      'Goals bonus',                  d.goals_bonus),
            ('8', NULL,      'Retention Points pay',         d.retention_points_pay)
          ) AS v(sort, code, label, amount)
        CROSS JOIN LATERAL (
          SELECT jsonb_build_object('sort', v.sort, 'code', v.code, 'label', v.label, 'amount', ROUND(v.amount, 2)) AS l
        ) j
        WHERE v.amount IS NOT NULL AND ROUND(v.amount, 2) <> 0
      )
    ) AS x
    FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report_id
  ) s;

  RETURN jsonb_build_object(
    'week_ending_date', v_week_end,
    'week_start_date',  v_week_start,
    'has_cpr_report',   v_report_id IS NOT NULL,
    'hours',            COALESCE(v_hours, '[]'::jsonb),
    'time_off',         COALESCE(v_time_off, '[]'::jsonb),
    'bonuses',          COALESCE(v_bonuses, '[]'::jsonb)
  );
END;
$function$;

COMMENT ON FUNCTION public.team_payroll_week(uuid, date) IS
  'One week of payroll facts for the Payroll tab in the Team module: worked and paid-time-off hours for anyone paid by the hour, every individual paid day off in the week, and the bonuses due off that week''s CPR. Week runs Sunday to Saturday; leave the date null for the current week.';

GRANT EXECUTE ON FUNCTION public.team_payroll_week(uuid, date) TO authenticated, service_role;