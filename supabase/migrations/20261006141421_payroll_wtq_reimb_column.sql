-- Win the Quarter trip prize shows on the Team > Payroll tab as REIMB.
-- The prize sits on the last CPR week of the quarter (quarter_close_wtq). It is
-- due that week; unticking it on the payroll page (receipts not in) moves it to
-- the following week. wtq_reimb_week holds the week it is paid; NULL means the
-- quarter's last week.
ALTER TABLE public.weekly_cpr_team_detail ADD COLUMN IF NOT EXISTS wtq_reimb_week date;
COMMENT ON COLUMN public.weekly_cpr_team_detail.wtq_reimb_week IS
  'Week (Saturday) the Win the Quarter trip prize is paid as REIMB. NULL = the quarter''s last week. Moved a week on by unticking it on the payroll page.';

CREATE OR REPLACE FUNCTION public.wtq_reimb_items(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(detail_id uuid, team_member_id uuid, amount numeric, close_week date, pay_week date)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- Every WtQ prize that belongs on this week's payroll page: written on or
  -- before this week, and not yet paid in an earlier week.
  SELECT d.id, d.team_member_id, ROUND(d.wtq_trip_dollars, 2), r.week_ending_date,
         COALESCE(d.wtq_reimb_week, r.week_ending_date)
  FROM public.weekly_cpr_team_detail d
  JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
  WHERE r.agency_id = p_agency_id
    AND COALESCE(d.wtq_trip_dollars, 0) > 0
    AND r.week_ending_date <= p_week_end
    AND COALESCE(d.wtq_reimb_week, r.week_ending_date) >= p_week_end
$function$;
REVOKE ALL ON FUNCTION public.wtq_reimb_items(uuid, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.wtq_reimb_items(uuid, date) TO service_role;

CREATE OR REPLACE FUNCTION public.wtq_reimb_set(p_agency_id uuid, p_detail_id uuid, p_week_ending_date date, p_paid boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_found boolean;
  v_lock  jsonb;
  v_week  date;
BEGIN
  PERFORM public.require_login('admin');
  SELECT EXISTS (SELECT 1 FROM public.wtq_reimb_items(p_agency_id, p_week_ending_date) w
                 WHERE w.detail_id = p_detail_id) INTO v_found;
  IF NOT v_found THEN
    RAISE EXCEPTION 'That trip prize is not on this week.';
  END IF;
  v_lock := public.week_pay_lock(p_agency_id, p_week_ending_date);
  IF COALESCE((v_lock->>'payroll_received')::boolean, false) THEN
    RAISE EXCEPTION 'Payroll for this week is already in, so the trip prize cannot move now.';
  END IF;
  v_week := CASE WHEN p_paid THEN p_week_ending_date ELSE p_week_ending_date + 7 END;
  UPDATE public.weekly_cpr_team_detail SET wtq_reimb_week = v_week WHERE id = p_detail_id;
  RETURN jsonb_build_object('ok', true, 'pay_week', v_week);
END;
$function$;
REVOKE ALL ON FUNCTION public.wtq_reimb_set(uuid, uuid, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.wtq_reimb_set(uuid, uuid, date, boolean) TO authenticated, service_role;

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
  v_lock       jsonb;
BEGIN
  PERFORM public.require_login('admin');
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

  v_lock := public.week_pay_lock(p_agency_id, v_week_end);

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
    LEFT JOIN public.marketing_points_weekly(p_agency_id, v_week_end) mp
      ON mp.team_member_id = d.team_member_id
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
  ),
  pact AS (
    -- The frozen paycheck for this week, if payroll has transmitted. One row per
    -- person; its presence is what flips a row from computed to actual.
    SELECT pd.team_member_id,
           COALESCE((pd.raw_earnings->'items'->'SALARY'->>'period')::numeric, 0)
         + COALESCE((pd.raw_earnings->'items'->'REGULAR'->>'period')::numeric, 0)
         + COALESCE((pd.raw_earnings->'items'->'HOURLY'->>'period')::numeric, 0)
         + COALESCE((pd.raw_earnings->'items'->'PTO'->>'period')::numeric, 0)
         + COALESCE((pd.raw_earnings->'items'->'- O/TIME'->>'period')::numeric, 0) AS pay,
           COALESCE((pd.raw_earnings->'items'->'1Comm'->>'period')::numeric, 0)   AS c1,
           COALESCE((pd.raw_earnings->'items'->'2Team'->>'period')::numeric, 0)   AS c2,
           COALESCE((pd.raw_earnings->'items'->'3Market'->>'period')::numeric, 0) AS c3,
           COALESCE((pd.raw_earnings->'items'->'4Goals'->>'period')::numeric, 0)  AS c4,
           COALESCE((pd.raw_earnings->'items'->'5Manage'->>'period')::numeric, 0) AS c5,
           COALESCE((pd.raw_earnings->'items'->'LIFE *'->>'period')::numeric, 0)  AS add_in,
           COALESCE((pd.raw_earnings->'items'->'REIMB.'->>'period')::numeric, 0)  AS reimb
    FROM public.payroll_detail pd
    JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id
    WHERE pd.agency_id = p_agency_id
      AND pr.pay_period_end = v_week_end
  ),
  wq AS (
    -- Win the Quarter trip prize, paid as REIMB. quarter_close_wtq writes it on
    -- the last CPR week of the quarter. It is due that week unless it gets
    -- unticked on this page (receipts not in yet), which moves it a week on.
    SELECT w.team_member_id,
           ROUND(COALESCE(SUM(w.amount) FILTER (WHERE w.pay_week = v_week_end), 0), 2) AS due,
           jsonb_agg(jsonb_build_object(
             'detail_id', w.detail_id, 'amount', w.amount, 'quarter_end', w.close_week,
             'pay_week', w.pay_week, 'paid_this_week', (w.pay_week = v_week_end)
           ) ORDER BY w.close_week) AS items
    FROM public.wtq_reimb_items(p_agency_id, v_week_end) w
    GROUP BY w.team_member_id
  )
  SELECT COALESCE(jsonb_agg(x ORDER BY pay_ord, last_nm, first_nm), '[]'::jsonb)
    INTO v_people
  FROM (
    SELECT jsonb_build_object(
      'team_member_id', t.id,
      'name', CASE WHEN COALESCE(t.last_name, '') = '' THEN t.first_name ELSE t.last_name || ', ' || t.first_name END,
      'pay_type', t.pay_type,
      'pay_rate', t.pay_rate,
      'is_active', t.is_active,
      'worked_hours',        v.worked,
      'paid_time_off_hours', v.pto,
      'overtime_hours',      w.ot,
      'pay',                 z.pay,
      'from_payroll',        z.from_payroll,
      'codes', jsonb_build_object(
        '1Comm',   z.c1,
        '2Team',   z.c2,
        '3Market', z.c3,
        '4Goals',  z.c4,
        '5Manage', z.c5
      ),
      'add_in',            z.add_in,
      'reimb',             z.reimb,
      'wtq',               COALESCE(wq.items, '[]'::jsonb),
      'take_out',          z.take_out,
      'before_deductions', ROUND(COALESCE(z.pay, 0) + z.bonus_total + z.add_in + z.reimb, 2),
      'days',              COALESCE(hrs.days, '[]'::jsonb),
      'time_off',          COALESCE(toff.days_off, '[]'::jsonb),
      'lines',             COALESCE(lns.lines, '[]'::jsonb)
    ) AS x,
    CASE WHEN t.pay_type = 'HOURLY' THEN 0 WHEN t.pay_type = 'SALARY' THEN 1 ELSE 2 END AS pay_ord,
    LOWER(COALESCE(t.last_name, '')) AS last_nm,
    LOWER(COALESCE(t.first_name, '')) AS first_nm
    FROM public.team t
    LEFT JOIN hrs  ON hrs.team_member_id  = t.id
    LEFT JOIN toff ON toff.team_member_id = t.id
    LEFT JOIN bon  ON bon.team_member_id  = t.id
    LEFT JOIN lns  ON lns.team_member_id  = t.id
    LEFT JOIN pact ON pact.team_member_id = t.id
    LEFT JOIN wq   ON wq.team_member_id   = t.id
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
      -- Paycheck wins wherever there is one. No payroll row for the week means
      -- every figure stays the computed one, exactly as before.
      SELECT (pact.team_member_id IS NOT NULL) AS from_payroll,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.pay    ELSE w.pay                  END AS pay,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c1     ELSE COALESCE(bon.c1, 0)    END AS c1,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c2     ELSE COALESCE(bon.c2, 0)    END AS c2,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c3     ELSE COALESCE(bon.c3, 0)    END AS c3,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c4     ELSE COALESCE(bon.c4, 0)    END AS c4,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c5     ELSE COALESCE(bon.c5, 0)    END AS c5,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.add_in ELSE COALESCE(lns.add_in, 0) END AS add_in,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.reimb  ELSE COALESCE(wq.due, 0)     END AS reimb,
             COALESCE(lns.take_out, 0) AS take_out
    ) z0
    CROSS JOIN LATERAL (
      SELECT z0.from_payroll, z0.pay, z0.c1, z0.c2, z0.c3, z0.c4, z0.c5,
             z0.add_in, z0.reimb, z0.take_out,
             ROUND(z0.c1 + z0.c2 + z0.c3 + z0.c4 + z0.c5, 2) AS bonus_total
    ) z
    WHERE t.agency_id = p_agency_id
      AND (
        t.is_active
        OR z.bonus_total <> 0
        OR z.reimb <> 0
        OR v.worked <> 0
      )
  ) s;

  -- Leslie's monthly goals. The bot asks Marie on the 1st; her answer is what
  -- says whether the kids' goals were hit, so it belongs on this page.
  SELECT to_jsonb(g) INTO v_goals
  FROM (
    SELECT c.review_month, c.sent_at, c.sent_ok, c.bonus_paid,
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
    'lock',             v_lock,
    'payroll_received', COALESCE((v_lock->>'payroll_received')::boolean, false),
    'people',           COALESCE(v_people, '[]'::jsonb),
    'leslie_goals',     COALESCE(v_goals, 'null'::jsonb)
  );
END;
$function$;

