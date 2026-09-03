-- Peter correction 2026-09-02: the test is "terminated anywhere in the week", not "did not
-- finish the week". Migrations 20260903000629 and 20260903010315 used end_date < that week's
-- Friday, which still charged misses and still showed a checklist for someone whose last day
-- was the Friday or the Saturday. Wrong bar.
--
-- Correct test: end_date IS NOT NULL AND end_date <= that week's Saturday. Anyone whose last
-- day lands anywhere inside the week is out of the misses math and off the checklist surfaces
-- for that week. Weeks before their termination are unaffected - their end_date is later than
-- those Saturdays, so they are scored normally.
--
-- This does NOT touch the seat proration in 20260902225805. The required quotes and sales for
-- a part-week seat stay prorated by workdays worked. What is ASKED of the team is prorated;
-- what is CHARGED to the person is zero.

CREATE OR REPLACE FUNCTION public.get_weekly_cpr_requirements(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, carryover numeric, personal_misses integer, team_misses integer, missed integer, cost numeric, total numeric, modified integer, quotes_discussed integer, paid numeric, owed numeric, buyback integer, net_quotes numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_cycle_start       date;
  v_first_week        date;
  v_loop_week         date;
  v_target_week_start date := p_week_ending_date - 6;
  v_state             jsonb;
  -- WtW requirements-adjustment buy-back (locked 2026-08-15) — added post-loop, below.
  v_cyc                record;
  v_targets2           record;
  v_totals2            record;
  v_team_carryover     int := 0;
  v_team_requirement   int;
  v_team_raw           int;
  v_team_net_raw       numeric;
  v_sp_qtd             numeric;
  v_sp_target          numeric;
  v_raw_pass           boolean;
  v_sp_pass            boolean;
  v_eligible           boolean;
BEGIN
  SELECT (ci.cycle_start)::date INTO v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_ending_date) ci;

  v_first_week := v_cycle_start + 6;

  IF v_first_week > p_week_ending_date THEN
    RETURN;
  END IF;

  SELECT jsonb_object_agg(m.tm_id::text, jsonb_build_object('carryover_input', 0))
  INTO   v_state
  FROM (
    SELECT team_id AS tm_id
      FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', v_target_week_start)
    UNION
    SELECT t.id AS tm_id
      FROM public.team t
      JOIN public.weekly_cpr_team_detail dd ON dd.team_member_id = t.id
      JOIN public.weekly_cpr_reports rr ON rr.id = dd.weekly_cpr_report_id
     WHERE t.agency_id           = p_agency_id
       AND t.category             = 'agency'
       AND COALESCE(t.role_level,'') <> 'Owner'
       AND t.is_admin_backoffice  = false
       AND t.is_test_user IS NOT TRUE
       AND rr.agency_id           = p_agency_id
       AND rr.week_ending_date    = p_week_ending_date
  ) m;

  IF v_state IS NULL THEN
    RETURN;
  END IF;

  v_loop_week := v_first_week;

  WHILE v_loop_week <= p_week_ending_date LOOP
    WITH
    members AS (
      SELECT
        (key)::uuid                              AS tm_id,
        (value->>'carryover_input')::numeric     AS carryover_input
      FROM jsonb_each(v_state)
    ),
    this_report AS (
      SELECT
        id AS report_id,
        (CASE WHEN COALESCE(shareds_done,       false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(texts_done,         false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(deposits_done,      false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(appts_done,         false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(tasks_done,         false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(cases_done,         false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(no_fu_task_done,    false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(new_opps_done,      false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(no_onboarding_done, false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(no_phone_done,      false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(bad_data_done,      false) THEN 0 ELSE 1 END
        )::integer AS week_team_misses
      FROM public.weekly_cpr_reports
      WHERE agency_id = p_agency_id AND week_ending_date = v_loop_week
    ),
    per_person AS (
      SELECT
        m.tm_id,
        m.carryover_input::numeric AS carryover,
        -- Peter ruling 2026-09-02: nobody terminated anywhere inside the week is charged
        -- misses for that week. v_loop_week is the Saturday, end_date is the last day worked.
        CASE
          WHEN t.end_date IS NOT NULL AND t.end_date <= v_loop_week THEN 0
          WHEN d.id IS NULL THEN 0
          ELSE
          (CASE WHEN COALESCE(d.scorecard_done, false) THEN 0 ELSE 1 END +
           CASE WHEN COALESCE(d.wrapup_done,    false) THEN 0 ELSE 1 END +
           CASE WHEN COALESCE(d.inbox_done,     false) THEN 0 ELSE 1 END +
           CASE WHEN d.code_reds IS NULL OR btrim(d.code_reds) = '' THEN 0
                ELSE (SELECT COUNT(*)
                        FROM regexp_split_to_table(d.code_reds, E'\r?\n') AS ln
                       WHERE btrim(ln) <> '')
           END)
        END::integer AS personal_misses,
        CASE
          WHEN t.end_date IS NOT NULL AND t.end_date <= v_loop_week THEN 0
          ELSE COALESCE((SELECT week_team_misses FROM this_report), 0)
        END::integer AS team_misses,
        COALESCE(d.quotes_discussed, 0)::integer AS quotes_discussed,
        COALESCE(d.quotes_modified, 0)::integer  AS modified,
        CASE
          WHEN COALESCE(d.start_date, t.start_date) IS NULL THEN 1.00
          ELSE (
            CASE
              WHEN GREATEST(1, ((v_loop_week - COALESCE(d.start_date, t.start_date)) / 7) + 1) <= 2 THEN 0.00
              WHEN GREATEST(1, ((v_loop_week - COALESCE(d.start_date, t.start_date)) / 7) + 1) <= 4 THEN 0.20
              WHEN GREATEST(1, ((v_loop_week - COALESCE(d.start_date, t.start_date)) / 7) + 1) <= 8 THEN 0.50
              ELSE 1.00
            END
          )
        END::numeric AS cost
      FROM members m
      JOIN public.team t ON t.id = m.tm_id
      LEFT JOIN public.weekly_cpr_team_detail d
        ON d.weekly_cpr_report_id = (SELECT report_id FROM this_report)
       AND d.team_member_id       = m.tm_id
    ),
    per_person_derived AS (
      SELECT
        tm_id, carryover, personal_misses, team_misses, modified, quotes_discussed, cost,
        (team_misses + personal_misses)::integer                                              AS missed,
        ROUND(((carryover + team_misses + personal_misses + modified) * cost)::numeric, 2)     AS total
      FROM per_person
    ),
    team_totals AS (
      SELECT
        SUM(quotes_discussed)::integer                                              AS team_quotes,
        SUM(carryover)::numeric                                                     AS team_carryover,
        SUM((missed + modified) * cost)::numeric                                    AS team_this_period_new,
        SUM(total)::numeric                                                         AS team_total_debt
      FROM per_person_derived
    ),
    allocated AS (
      SELECT
        ppd.tm_id,
        ppd.carryover, ppd.personal_misses, ppd.team_misses, ppd.missed,
        ppd.cost, ppd.total, ppd.modified, ppd.quotes_discussed,
        ROUND((CASE
          WHEN tt.team_quotes >= tt.team_total_debt
            THEN ppd.total
          WHEN tt.team_quotes >= tt.team_carryover
            THEN ppd.carryover +
                 CASE WHEN tt.team_this_period_new > 0
                      THEN (tt.team_quotes - tt.team_carryover)::numeric
                                 * ((ppd.missed + ppd.modified) * ppd.cost)::numeric
                                 / tt.team_this_period_new
                      ELSE 0 END
          ELSE
            CASE WHEN tt.team_carryover > 0
                 THEN tt.team_quotes::numeric * ppd.carryover::numeric
                            / tt.team_carryover
                 ELSE 0 END
        END)::numeric, 2) AS paid
      FROM per_person_derived ppd
      CROSS JOIN team_totals tt
    )
    SELECT COALESCE(
      jsonb_object_agg(
        a.tm_id::text,
        jsonb_build_object(
          'carryover_input',  ROUND((a.total - a.paid)::numeric, 2),
          'carryover',        ROUND(a.carryover::numeric, 2),
          'personal_misses',  a.personal_misses,
          'team_misses',      a.team_misses,
          'missed',           a.missed,
          'cost',             a.cost,
          'total',            a.total,
          'modified',         a.modified,
          'quotes_discussed', a.quotes_discussed,
          'paid',             a.paid,
          'owed',             ROUND((a.total - a.paid)::numeric, 2),
          'net_quotes',       ROUND((a.quotes_discussed - a.paid)::numeric, 2)
        )
      ),
      '{}'::jsonb
    )
    INTO v_state
    FROM allocated a;

    v_loop_week := v_loop_week + 7;
  END LOOP;

  -- WtW requirements-adjustment buy-back (locked 2026-08-15). Licensed teammates whose RAW
  -- quotes cleared their personal minimum (15 sales / 8 retention) but whose net (post-Paid/
  -- Owed walk above) fell short pay $10/quote and get those quotes back. Folded directly into
  -- net_quotes here — the one canonical place every consumer reads from — so every function
  -- that sums net_quotes for Win-the-Week purposes picks it up automatically. Gated on team
  -- eligibility only (enough raw quotes AND enough sales points to have been on track to win
  -- before requirements touched anything) — mirrors compute_wtw_requirements_adjustment's gate,
  -- computed independently here since that function calls THIS one and a call-cycle isn't
  -- possible. Team-pool-funded remainder (when individual buy-backs don't fully cover the gap)
  -- isn't attributable to one person, so it is NOT folded in here — it stays on
  -- weekly_cpr_reports.wtw_requirements_adjustment_quotes, added on top by team-level consumers.
  SELECT * INTO v_cyc FROM public.current_cycle_info(p_agency_id, p_week_ending_date);
  SELECT * INTO v_targets2 FROM public.compute_wtw_week_targets(p_agency_id, v_target_week_start);

  IF v_cyc.week_of_cycle <= 1 THEN
    v_team_carryover := 0;
  ELSE
    SELECT COALESCE(quotes_owed_next_week, 0) INTO v_team_carryover
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cyc.prior_week_ending_saturday;
    v_team_carryover := COALESCE(v_team_carryover, 0);
  END IF;
  v_team_requirement := v_targets2.quotes_fresh_needed + v_team_carryover;

  v_sp_target := public.compute_cumulative_sp_target(p_agency_id, v_cyc.week_of_cycle, v_cyc.cycle_start);
  SELECT * INTO v_totals2 FROM public.get_team_checkin_totals(p_agency_id, v_cyc.cycle_start, p_week_ending_date);
  -- Peter directive 2026-08-30: quarter-to-date sales points total up from the team
  -- detail rows, not from self-reported check-ins. See get_cpr_detail_sales_points_qtd.
  v_sp_qtd := public.get_cpr_detail_sales_points_qtd(p_agency_id, v_cyc.cycle_start, p_week_ending_date);

  SELECT COALESCE(SUM((value->>'quotes_discussed')::int), 0),
         COALESCE(SUM((value->>'net_quotes')::numeric), 0)
  INTO v_team_raw, v_team_net_raw
  FROM jsonb_each(v_state);

  v_raw_pass := v_team_raw >= v_team_requirement;
  v_sp_pass  := v_sp_qtd   >= v_sp_target;
  v_eligible := v_raw_pass AND v_sp_pass;

  IF v_eligible THEN
    WITH personal AS (
      SELECT
        t.id AS tm_id,
        CASE
          WHEN t.role_level IN ('Account Manager','Unit Manager') AND t.role_category = 'Sales' THEN 15
          WHEN t.role_level IN ('Account Manager','Unit Manager') AND t.role_category = 'Retention' THEN 8
          ELSE NULL
        END AS personal_min
      FROM public.team t
      WHERE t.agency_id = p_agency_id AND t.category = 'agency' AND COALESCE(t.license_pc, false) = true
    ),
    current_state AS (
      SELECT (key)::uuid AS tm_id, value AS v FROM jsonb_each(v_state)
    ),
    buyback_calc AS (
      SELECT
        cs.tm_id,
        CASE
          WHEN p.personal_min IS NOT NULL
               AND (cs.v->>'quotes_discussed')::int >= p.personal_min
               AND (cs.v->>'net_quotes')::numeric < p.personal_min
            THEN ROUND(GREATEST(0, p.personal_min - (cs.v->>'net_quotes')::numeric))::int
          ELSE 0
        END AS buyback
      FROM current_state cs
      LEFT JOIN personal p ON p.tm_id = cs.tm_id
    )
    SELECT jsonb_object_agg(
      cs.tm_id::text,
      cs.v || jsonb_build_object(
        'buyback',    COALESCE(bc.buyback, 0),
        'net_quotes', ROUND(((cs.v->>'net_quotes')::numeric + COALESCE(bc.buyback, 0))::numeric, 2)
      )
    )
    INTO v_state
    FROM current_state cs
    LEFT JOIN buyback_calc bc ON bc.tm_id = cs.tm_id;
  ELSE
    SELECT jsonb_object_agg((key)::text, value || jsonb_build_object('buyback', 0))
    INTO v_state
    FROM jsonb_each(v_state);
  END IF;

  RETURN QUERY
  SELECT
    (key)::uuid                                  AS team_member_id,
    (value->>'carryover')::numeric               AS carryover,
    (value->>'personal_misses')::integer         AS personal_misses,
    (value->>'team_misses')::integer             AS team_misses,
    (value->>'missed')::integer                  AS missed,
    (value->>'cost')::numeric                    AS cost,
    (value->>'total')::numeric                   AS total,
    (value->>'modified')::integer                AS modified,
    (value->>'quotes_discussed')::integer        AS quotes_discussed,
    (value->>'paid')::numeric                    AS paid,
    (value->>'owed')::numeric                    AS owed,
    COALESCE((value->>'buyback')::integer, 0)    AS buyback,
    (value->>'net_quotes')::numeric              AS net_quotes
  FROM jsonb_each(v_state);
END;
$function$;

CREATE OR REPLACE FUNCTION public.compute_scorecard_done_for_cpr_week(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, tier text, required_entry_type text, matching_count integer, threshold integer, done boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_week_start date;
  v_today date;
  v_effective_end date;
BEGIN
  v_week_start := p_week_ending_date - 6;  -- Sunday of the CPR week
  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_effective_end := LEAST(v_today, p_week_ending_date);

  RETURN QUERY
  WITH tm AS (
    SELECT d.team_member_id, COALESCE(d.quotes_discussed, 0) AS quotes_discussed
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    JOIN public.team t ON t.id = d.team_member_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date = p_week_ending_date
      -- Peter ruling 2026-09-02: nobody terminated anywhere inside the week is scored on their
      -- checklist for that week. Returning no row leaves their stored value untouched.
      AND (t.end_date IS NULL OR t.end_date > p_week_ending_date)
  ),
  tiered AS (
    SELECT
      tm.team_member_id,
      tm.quotes_discussed,
      public.fit_scorecard_tenure_tier(tm.team_member_id, p_week_ending_date) AS tier
    FROM tm
  ),
  reqs AS (
    SELECT
      t.team_member_id,
      t.quotes_discussed,
      t.tier,
      public.fit_scorecard_entry_type_for_tenure(t.tier) AS required_entry_type
    FROM tiered t
  ),
  -- Days this person was actually expected to work, within the elapsed week.
  expected AS (
    SELECT r.team_member_id, COUNT(*)::int AS days_expected
    FROM reqs r
    CROSS JOIN generate_series(v_week_start, v_effective_end, INTERVAL '1 day') AS d
    WHERE EXTRACT(dow FROM d) BETWEEN 1 AND 5
      -- agency closed for a holiday: nobody is expected to work
      AND NOT EXISTS (
        SELECT 1 FROM public.company_holidays h
        WHERE h.agency_id = p_agency_id
          AND h.is_active
          AND h.observance = 'closed'
          AND h.holiday_date = d::date
      )
      -- this person had an approved whole-day absence
      AND NOT EXISTS (
        SELECT 1 FROM public.time_off_requests tor
        WHERE tor.agency_id = p_agency_id
          AND tor.requester_team_id = r.team_member_id
          AND tor.status = 'approved'
          AND tor.request_type IN ('time_off_full_day', 'sick')
          AND COALESCE(tor.partial_day, 'none') = 'none'
          AND d::date BETWEEN tor.start_date AND tor.end_date
      )
    GROUP BY r.team_member_id
  ),
  counts AS (
    SELECT s.team_member_id, s.entry_type, COUNT(*)::int AS c
    FROM public.fit_scorecards s
    WHERE s.agency_id = p_agency_id
      AND s.scorecard_date BETWEEN v_week_start AND p_week_ending_date
    GROUP BY s.team_member_id, s.entry_type
  ),
  final AS (
    SELECT
      r.team_member_id,
      r.tier,
      r.required_entry_type,
      COALESCE(c.c, 0) AS matching_count,
      CASE r.tier
        WHEN 'weeks_14_plus' THEN COALESCE(e.days_expected, 0)
        WHEN 'weeks_9_13'    THEN r.quotes_discussed
        WHEN 'weeks_1_8'     THEN GREATEST(r.quotes_discussed, COALESCE(e.days_expected, 0))
        ELSE COALESCE(e.days_expected, 0)
      END AS threshold
    FROM reqs r
    LEFT JOIN expected e ON e.team_member_id = r.team_member_id
    LEFT JOIN counts c
      ON c.team_member_id = r.team_member_id
     AND c.entry_type    = r.required_entry_type
  )
  SELECT
    f.team_member_id,
    f.tier,
    f.required_entry_type,
    f.matching_count,
    f.threshold,
    (f.matching_count >= f.threshold) AS done
  FROM final f;
END;
$function$;
