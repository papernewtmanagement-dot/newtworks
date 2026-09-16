-- The payroll codes changed on 2026-07-11. The old six (0Advnce, 1Health, 2Serve,
-- 3True, 4Manage, 5Goals) have paid nothing since 2026-07-04. The live five are
-- below, each one checked against the actual payroll summaries to the penny for
-- weeks ending 2026-08-22 and 2026-08-29:
--   1Comm   commission
--   2Team   sales pool share + retention pool share (the bonus column)
--   3Market marketing points, which are already dollar amounts
--   4Goals  goals bonus + health bonus, combined
--   5Manage manager bonus
-- 6WtQ (Win the Quarter) exists on the runs but has never carried an amount, so
-- it is left out until it pays something.
--
-- Also returns the Leslie monthly goals check-in: the message that goes to Marie
-- on the 1st, and her answer once it lands.
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
  v_hours      jsonb;
  v_time_off   jsonb;
  v_bonuses    jsonb;
  v_goals      jsonb;
BEGIN
  -- Sunday to Saturday, Central, same boundary every other week-bounded figure uses.
  -- Any date given is snapped forward to the Saturday that ends its week.
  SELECT d + ((6 - EXTRACT(DOW FROM d)::int) % 7)
    INTO v_week_end
  FROM (
    SELECT COALESCE(p_week_ending_date, (now() AT TIME ZONE 'America/Chicago')::date) AS d
  ) s;
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
      'worked_hours',        ROUND(COALESCE(SUM(h.hours), 0), 2),
      'paid_time_off_hours', ROUND(COALESCE(SUM(h.paid_time_off_hours), 0), 2),
      'overtime_hours',      ROUND(GREATEST(0, COALESCE(SUM(h.hours), 0) - 40), 2),
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

  -- Step 4 · what to type into payroll, under the codes in use since 2026-07-11.
  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'name'), '[]'::jsonb) INTO v_bonuses
  FROM (
    SELECT jsonb_build_object(
      'team_member_id', d.team_member_id,
      'name', TRIM(COALESCE(d.first_name, '') || ' ' || COALESCE(d.last_name, '')),
      'total', ROUND(
        COALESCE(d.commission, 0)
        + COALESCE(d.sales_pool_share, 0) + COALESCE(d.retention_pool_share, 0)
        + COALESCE(mp.points, 0)
        + COALESCE(d.goals_bonus, 0) + COALESCE(d.health_bonus, 0)
        + COALESCE(d.manager_bonus, 0)
      , 2),
      'lines', (
        SELECT COALESCE(jsonb_agg(j.l ORDER BY j.l->>'sort'), '[]'::jsonb)
        FROM (
          VALUES
            ('1', '1Comm',   'Commission',    COALESCE(d.commission, 0)),
            ('2', '2Team',   'Team bonus',    COALESCE(d.sales_pool_share, 0) + COALESCE(d.retention_pool_share, 0)),
            ('3', '3Market', 'Marketing',     COALESCE(mp.points, 0)),
            ('4', '4Goals',  'Goals',         COALESCE(d.goals_bonus, 0) + COALESCE(d.health_bonus, 0)),
            ('5', '5Manage', 'Manager',       COALESCE(d.manager_bonus, 0))
          ) AS v(sort, code, label, amount)
        CROSS JOIN LATERAL (
          SELECT jsonb_build_object('sort', v.sort, 'code', v.code, 'label', v.label, 'amount', ROUND(v.amount, 2)) AS l
        ) j
        WHERE ROUND(v.amount, 2) <> 0
      )
    ) AS x
    FROM public.weekly_cpr_team_detail d
    LEFT JOIN public.marketing_points mp
      ON mp.agency_id = p_agency_id
     AND mp.team_member_id = d.team_member_id
     AND mp.week_end_date = v_week_end
    WHERE d.weekly_cpr_report_id = v_report_id
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
    'hours',            COALESCE(v_hours, '[]'::jsonb),
    'time_off',         COALESCE(v_time_off, '[]'::jsonb),
    'bonuses',          COALESCE(v_bonuses, '[]'::jsonb),
    'leslie_goals',     COALESCE(v_goals, 'null'::jsonb)
  );
END;
$function$;
