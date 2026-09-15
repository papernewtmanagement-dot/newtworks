-- team_payroll_week now returns ONE merged row per person instead of three
-- separate lists the page had to stitch together. Each row carries the wages for
-- the week, the five bonus codes, the stipend added in, everything taken out,
-- and the total before deductions. The bonus subtotal is gone -- it was never a
-- number anyone types into payroll.
--
-- Wages: salaried people are paid their weekly rate. Hourly people are paid
-- worked hours up to 40 at rate, anything over 40 at time and a half, plus paid
-- time off at straight rate. Paid time off never counts toward the 40, per the
-- agency's own time-off rule.

CREATE OR REPLACE FUNCTION public.team_payroll_week(p_agency_id uuid, p_week_ending_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_week_end   date;
  v_week_start date;
  v_report_id  uuid;
  v_people     jsonb;
  v_goals      jsonb;
BEGIN
  -- Sunday to Saturday, Central, same boundary every other week-bounded figure
  -- uses. Any date given is snapped forward to the Saturday that ends its week.
  SELECT d + ((6 - EXTRACT(DOW FROM d)::int) % 7)
    INTO v_week_end
  FROM (
    SELECT COALESCE(p_week_ending_date, (now() AT TIME ZONE 'America/Chicago')::date) AS d
  ) s;
  v_week_start := v_week_end - 6;

  SELECT r.id INTO v_report_id
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_week_end;

  WITH hrs AS (
    -- Worked hours come from the same function the CPR reads, so the payroll
    -- tab and the CPR can never show different numbers.
    SELECT h.team_member_id,
           ROUND(COALESCE(SUM(h.hours), 0), 2)               AS worked_hours,
           ROUND(COALESCE(SUM(h.paid_time_off_hours), 0), 2) AS pto_hours,
           COALESCE(
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
           ) AS days
    FROM public.get_weekly_cpr_hours(p_agency_id, v_week_end) h
    GROUP BY h.team_member_id
  ),
  toff AS (
    -- Every individual paid day off that lands in this week. Read straight off
    -- the requests so back-office people who sit outside the CPR still show.
    SELECT tor.requester_team_id AS team_member_id,
           ROUND(SUM(public.time_off_day_hours(tor.request_type, tor.partial_day)), 2) AS pto_hours,
           jsonb_agg(
             jsonb_build_object(
               'work_date', d::date,
               'label', public.time_off_display_label(tor.request_type, tor.is_paid),
               'partial_day', tor.partial_day,
               'hours', public.time_off_day_hours(tor.request_type, tor.partial_day),
               'notes', tor.notes
             ) ORDER BY d
           ) AS days_off
    FROM public.time_off_requests tor
    CROSS JOIN LATERAL generate_series(tor.start_date, tor.end_date, '1 day'::interval) AS d
    WHERE tor.agency_id = p_agency_id
      AND tor.status    = 'approved'
      AND tor.is_paid IS TRUE
      AND tor.request_type NOT IN ('remote_day', 'remote_half_day')
      AND public.time_off_day_hours(tor.request_type, tor.partial_day) > 0
      AND d::date BETWEEN v_week_start AND v_week_end
    GROUP BY tor.requester_team_id
  ),
  bon AS (
    -- The codes in use since 2026-07-11.
    SELECT d.team_member_id,
           ROUND(COALESCE(d.commission, 0), 2) AS c1,
           ROUND(COALESCE(d.sales_pool_share, 0) + COALESCE(d.retention_pool_share, 0), 2) AS c2,
           ROUND(COALESCE(mp.points, 0), 2) AS c3,
           ROUND(COALESCE(d.goals_bonus, 0) + COALESCE(d.health_bonus, 0), 2) AS c4,
           ROUND(COALESCE(d.manager_bonus, 0), 2) AS c5
    FROM public.weekly_cpr_team_detail d
    LEFT JOIN public.marketing_points mp
      ON mp.agency_id = p_agency_id
     AND mp.team_member_id = d.team_member_id
     AND mp.week_end_date = v_week_end
    WHERE d.weekly_cpr_report_id = v_report_id
  ),
  lns AS (
    SELECT l.team_member_id,
           COALESCE(ROUND(SUM(l.weekly_amount) FILTER (WHERE l.line_type =  'life_stipend'), 2), 0) AS add_in,
           COALESCE(ROUND(SUM(l.weekly_amount) FILTER (WHERE l.line_type <> 'life_stipend'), 2), 0) AS take_out,
           jsonb_agg(
             jsonb_build_object(
               'id', l.id, 'line_type', l.line_type, 'label', l.label,
               'weekly_amount', l.weekly_amount, 'monthly_premium', l.monthly_premium,
               'agency_paid_weekly', l.agency_paid_weekly, 'notes', l.notes
             ) ORDER BY l.line_type, l.label
           ) AS lines
    FROM public.team_payroll_lines l
    WHERE l.is_active
    GROUP BY l.team_member_id
  )
  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'name'), '[]'::jsonb)
    INTO v_people
  FROM (
    SELECT jsonb_build_object(
      'team_member_id', t.id,
      'name', TRIM(t.first_name || ' ' || COALESCE(t.last_name, '')),
      'pay_type', t.pay_type,
      'pay_rate', t.pay_rate,
      'is_active', t.is_active,
      'worked_hours',        v.worked,
      'paid_time_off_hours', v.pto,
      'overtime_hours',      w.ot,
      'pay',                 w.pay,
      'codes', jsonb_build_object(
        '1Comm',   COALESCE(bon.c1, 0),
        '2Team',   COALESCE(bon.c2, 0),
        '3Market', COALESCE(bon.c3, 0),
        '4Goals',  COALESCE(bon.c4, 0),
        '5Manage', COALESCE(bon.c5, 0)
      ),
      'add_in',            z.add_in,
      'take_out',          z.take_out,
      'before_deductions', ROUND(COALESCE(w.pay, 0) + z.bonus_total + z.add_in, 2),
      'days',              COALESCE(hrs.days, '[]'::jsonb),
      'time_off',          COALESCE(toff.days_off, '[]'::jsonb),
      'lines',             COALESCE(lns.lines, '[]'::jsonb)
    ) AS x
    FROM public.team t
    LEFT JOIN hrs  ON hrs.team_member_id  = t.id
    LEFT JOIN toff ON toff.team_member_id = t.id
    LEFT JOIN bon  ON bon.team_member_id  = t.id
    LEFT JOIN lns  ON lns.team_member_id  = t.id
    CROSS JOIN LATERAL (
      SELECT COALESCE(hrs.worked_hours, 0) AS worked,
             CASE WHEN hrs.team_member_id IS NOT NULL
                  THEN COALESCE(hrs.pto_hours, 0)
                  ELSE COALESCE(toff.pto_hours, 0)
             END AS pto
    ) v
    CROSS JOIN LATERAL (
      SELECT ROUND(GREATEST(0, v.worked - 40), 2) AS ot,
             CASE
               WHEN t.pay_type = 'SALARY' THEN ROUND(COALESCE(t.pay_rate, 0), 2)
               WHEN t.pay_type = 'HOURLY' THEN ROUND(
                 COALESCE(t.pay_rate, 0)
                 * (LEAST(v.worked, 40) + GREATEST(v.worked - 40, 0) * 1.5 + v.pto)
               , 2)
               ELSE NULL
             END AS pay
    ) w
    CROSS JOIN LATERAL (
      SELECT COALESCE(bon.c1, 0) + COALESCE(bon.c2, 0) + COALESCE(bon.c3, 0)
           + COALESCE(bon.c4, 0) + COALESCE(bon.c5, 0) AS bonus_total,
             COALESCE(lns.add_in, 0)   AS add_in,
             COALESCE(lns.take_out, 0) AS take_out
    ) z
    WHERE t.agency_id = p_agency_id
      AND (
        t.is_active
        OR z.bonus_total <> 0
        OR v.worked <> 0
      )
  ) s;

  -- Leslie's monthly goals. The bot asks Marie on the 1st; her answer is what
  -- says whether the kids' goals were hit, so it belongs on this page.
  SELECT to_jsonb(g) INTO v_goals
  FROM (
    SELECT c.review_month, c.sent_at, c.sent_ok,
           c.marie_reply_text, c.marie_reply_at,
           (c.marie_reply_text IS NOT NULL) AS answered
    FROM public.leslie_monthly_checkin c
    WHERE c.agency_id = p_agency_id
      AND c.sent_at IS NOT NULL
      AND c.sent_at <= (v_week_end + 1)::timestamptz
    ORDER BY c.review_month DESC
    LIMIT 1
  ) g;

  RETURN jsonb_build_object(
    'week_ending_date', v_week_end,
    'week_start_date',  v_week_start,
    'has_cpr_report',   v_report_id IS NOT NULL,
    'people',           COALESCE(v_people, '[]'::jsonb),
    'leslie_goals',     COALESCE(v_goals, 'null'::jsonb)
  );
END;
$function$;
