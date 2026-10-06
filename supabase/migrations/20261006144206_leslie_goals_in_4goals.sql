-- Leslie's monthly goals money lands in 4Goals on the Team > Payroll tab.
-- Leslie has no CPR row, so 4Goals (goals_bonus + health_bonus from the CPR)
-- never carried it. The answer row now holds the amount and the week it is paid.
ALTER TABLE public.leslie_monthly_checkin ADD COLUMN IF NOT EXISTS goals_bonus numeric;
ALTER TABLE public.leslie_monthly_checkin ADD COLUMN IF NOT EXISTS bonus_week date;
COMMENT ON COLUMN public.leslie_monthly_checkin.goals_bonus IS 'Goals money for the month: full monthly amount on a yes, 0 on a no, NULL when the answer is neither.';
COMMENT ON COLUMN public.leslie_monthly_checkin.bonus_week IS 'Payroll week (Saturday) the goals money goes in 4Goals: first check date on or after the question, skipping weeks already paid.';

INSERT INTO public.settings (agency_id, setting_key, setting_value)
SELECT '126794dd-25ff-47d2-a436-724499733365', k, v
FROM (VALUES ('leslie_goals_team_id', '6c9e8570-7e2d-41c9-b19d-60379b158d13'), ('leslie_goals_bonus_monthly', '600')) x(k, v)
WHERE NOT EXISTS (SELECT 1 FROM public.settings s
                  WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.setting_key = x.k);

CREATE OR REPLACE FUNCTION public.leslie_monthly_record_reply(p_agency_id uuid, p_telegram_user_id bigint, p_text text, p_message_id bigint DEFAULT NULL::bigint, p_force boolean DEFAULT false, p_window_hours integer DEFAULT 72, p_reply_to_message_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_marie_team_id uuid;
  v_speaker       uuid;
  v_row           public.leslie_monthly_checkin%ROWTYPE;
  v_via           text;
  v_amount        numeric;
  v_week          date;
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN jsonb_build_object('recorded', false, 'reason', 'empty_text');
  END IF;

  SELECT setting_value::uuid INTO v_marie_team_id
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'leslie_goals_answerer_team_id';

  SELECT t.id INTO v_speaker
  FROM public.team t
  WHERE t.agency_id = p_agency_id AND t.telegram_user_id = p_telegram_user_id;

  IF v_speaker IS NULL OR v_marie_team_id IS NULL OR v_speaker <> v_marie_team_id THEN
    RETURN jsonb_build_object('recorded', false, 'reason', 'not_the_answerer');
  END IF;

  -- A reply to the question itself answers that month, whenever it comes.
  IF p_reply_to_message_id IS NOT NULL THEN
    SELECT * INTO v_row
    FROM public.leslie_monthly_checkin c
    WHERE c.agency_id = p_agency_id
      AND c.sent_message_id = p_reply_to_message_id
      AND c.marie_reply_text IS NULL
    ORDER BY c.sent_at DESC
    LIMIT 1;
    IF v_row.id IS NOT NULL THEN
      v_via := 'reply_to_question';
    END IF;
  END IF;

  IF v_row.id IS NULL THEN
    SELECT * INTO v_row
    FROM public.leslie_monthly_checkin c
    WHERE c.agency_id = p_agency_id
      AND c.sent_at IS NOT NULL
      AND c.marie_reply_text IS NULL
    ORDER BY c.sent_at DESC
    LIMIT 1;

    IF v_row.id IS NULL THEN
      RETURN jsonb_build_object('recorded', false, 'reason', 'nothing_waiting');
    END IF;

    IF NOT p_force AND now() - v_row.sent_at > make_interval(hours => p_window_hours) THEN
      RETURN jsonb_build_object('recorded', false, 'reason', 'outside_window',
                                'review_month', v_row.review_month,
                                'window_hours', p_window_hours);
    END IF;
    v_via := CASE WHEN p_force THEN 'goals_command' ELSE 'in_window' END;
  END IF;

  -- The money that goes in 4Goals: the monthly amount on a yes, nothing on a
  -- no, left blank when the answer is neither. It is paid on the first check
  -- date on or after the question goes out (pay date = the Saturday the week
  -- ends + 6); a week whose payroll is already in is skipped to the next one.
  SELECT CASE
           WHEN p_text ~* '^\s*(yes|yeah|yep|y)\M' THEN
             (SELECT NULLIF(setting_value, '')::numeric FROM public.settings
              WHERE agency_id = p_agency_id AND setting_key = 'leslie_goals_bonus_monthly')
           WHEN p_text ~* '^\s*(no|nope|n)\M' THEN 0
         END INTO v_amount;
  v_week := (v_row.sent_at AT TIME ZONE 'America/Chicago')::date - 6;
  v_week := v_week + ((6 - EXTRACT(DOW FROM v_week)::int) % 7);
  WHILE EXISTS (SELECT 1 FROM public.payroll_runs pr
                WHERE pr.agency_id = p_agency_id AND pr.pay_period_end = v_week) LOOP
    v_week := v_week + 7;
  END LOOP;

  UPDATE public.leslie_monthly_checkin
  SET marie_reply_text = p_text,
      marie_reply_at = now(),
      marie_reply_message_id = p_message_id,
      goals_bonus = v_amount,
      bonus_week = v_week,
      updated_at = now()
  WHERE id = v_row.id;

  RETURN jsonb_build_object('recorded', true, 'review_month', v_row.review_month, 'via', v_via,
                            'goals_bonus', v_amount, 'bonus_week', v_week);
END;
$function$;

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
  lg AS (
    -- Leslie's monthly goals money, in 4Goals on the week it is paid
    -- (leslie_monthly_record_reply sets the amount and the week).
    SELECT (SELECT NULLIF(s.setting_value, '')::uuid FROM public.settings s
            WHERE s.agency_id = p_agency_id AND s.setting_key = 'leslie_goals_team_id') AS team_member_id,
           ROUND(COALESCE(SUM(c.goals_bonus), 0), 2) AS amount
    FROM public.leslie_monthly_checkin c
    WHERE c.agency_id = p_agency_id AND c.bonus_week = v_week_end
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
    LEFT JOIN lg   ON lg.team_member_id   = t.id
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
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c4     ELSE COALESCE(bon.c4, 0) + COALESCE(lg.amount, 0) END AS c4,
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
    SELECT c.review_month, c.sent_at, c.sent_ok, c.bonus_paid, c.goals_bonus, c.bonus_week,
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

-- The two answers on file. August was paid on the Sep 4 check (week ending
-- Aug 29). September's answer came in after the Oct 2 check went out, so it
-- goes on the next one (week ending Oct 3).
UPDATE public.leslie_monthly_checkin SET goals_bonus = 600, bonus_week = '2026-08-29'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND review_month = '2026-08-01';
UPDATE public.leslie_monthly_checkin SET goals_bonus = 600, bonus_week = '2026-10-03'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND review_month = '2026-09-01';

