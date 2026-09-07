-- CPR: mid-week departures (John Kostov, last day Tue 2026-09-01) broke four things on the
-- week ending 2026-09-05. Root cause in every case: a roster built on is_active / archived_at
-- as of SATURDAY, so a teammate who left mid-week vanished from the week he was still part of
-- (the CPR snapshot rule says anyone on the team Monday morning counts for that week).
--   1. compute_weekly_comp_residual_pool dropped him from the roster: his row got no pay, and
--      ~$11k of his quarter-to-date base/commission/prior bonuses stopped coming out of the
--      envelope, which handed the rest of the team a $13,510 "pool".
--   2. compute_pool_carveouts / compute_warning_trigger used the same roster call.
--   3. The QTD carve-out accruals were today's weekly amount x weeks elapsed, so the roster
--      change also repriced every prior week's carve (per-week ledger now).
--   4. compose_weekly_cpr_html filtered the digest pay table on is_active on top of the snapshot rule.
-- Plus get_weekly_cpr_hours gave a salaried teammate 8 hours on days after his last day.

-- get_weekly_cpr_hours: a salaried teammate's assumed 8-hour day now stops at their last day
-- worked and starts on their first. Before this, John Kostov (last day Tue 2026-09-01) showed
-- 8 hours on Wednesday and Thursday of his termination week. Hourly people were never affected
-- (their hours come from the time clock). Live start/end dates win over the week's snapshot
-- because a snapshot can carry a planned end date that later moved.
CREATE OR REPLACE FUNCTION public.get_weekly_cpr_hours(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, day_idx integer, day_label text, work_date date, hours numeric, location text)
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
LEFT JOIN remote_per_day rpd
  ON rpd.team_member_id = at.team_id
 AND rpd.work_date      = wd.work_date
ORDER BY at.team_id, wd.day_idx;
$function$;


DO $do$
DECLARE
  v_src text;
BEGIN
  ------------------------------------------------------------------------------------------
  -- compute_weekly_comp_residual_pool
  ------------------------------------------------------------------------------------------
  v_src := pg_get_functiondef('public.compute_weekly_comp_residual_pool(uuid, date)'::regprocedure);
  v_src := public.fn_source_replace_exact(v_src,
    $q$WITH roster AS (SELECT et.team_id AS id, et.first_name, et.last_name, et.role AS r_role, et.role_category AS r_role_category, et.role_level AS r_role_level, COALESCE(dsnap.pay_type, t.pay_type) AS pay_type, COALESCE(dsnap.pay_rate, t.pay_rate) AS pay_rate, COALESCE(dsnap.work_location, t.work_location) AS work_location, et.start_date, COALESCE(dsnap.license_pc, t.license_pc) AS license_pc, COALESCE(dsnap.license_lh, t.license_lh) AS license_lh, COALESCE(dsnap.license_ips, t.license_ips) AS license_ips, COALESCE(dsnap.weekly_health_benefit_agency_paid, t.weekly_health_benefit_agency_paid) AS weekly_health_benefit_agency_paid FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et JOIN public.team t ON t.id = et.team_id LEFT JOIN public.weekly_cpr_reports rr ON rr.agency_id = p_agency_id AND rr.week_ending_date = p_week_end_date LEFT JOIN public.weekly_cpr_team_detail dsnap ON dsnap.weekly_cpr_report_id = rr.id AND dsnap.team_member_id = et.team_id),$q$,
    $q$WITH roster AS (
    /* Cost roster + this-week roster in one (2026-09-06).
       Everyone who drew pay from the envelope at any point in this cycle stays on the roster,
       so their base, commissions, manager bonus and prior bonuses keep coming out of the pool
       after they leave. in_week marks who was on the team Monday morning of THIS week (the
       CPR snapshot rule): only they share this week's pool and only they are returned.
       Before this, a teammate archived mid-week vanished from the roster, his quarter-to-date
       pay dropped out of the subtractions, and the pool ballooned (week ending 2026-09-05). */
    SELECT t.id AS id,
      COALESCE(dsnap.first_name, t.first_name) AS first_name, COALESCE(dsnap.last_name, t.last_name) AS last_name,
      COALESCE(dsnap.role, t.role) AS r_role, COALESCE(dsnap.role_category, t.role_category) AS r_role_category, COALESCE(dsnap.role_level, t.role_level) AS r_role_level,
      COALESCE(dsnap.pay_type, t.pay_type) AS pay_type, COALESCE(dsnap.pay_rate, t.pay_rate) AS pay_rate, COALESCE(dsnap.work_location, t.work_location) AS work_location,
      COALESCE(t.start_date, dsnap.start_date) AS start_date,
      /* last day worked. Live end_date first: a snapshot can carry a planned date that moved. */
      COALESCE(t.end_date, dsnap.end_date, (t.archived_at AT TIME ZONE 'America/Chicago')::date) AS end_date,
      COALESCE(dsnap.license_pc, t.license_pc) AS license_pc, COALESCE(dsnap.license_lh, t.license_lh) AS license_lh, COALESCE(dsnap.license_ips, t.license_ips) AS license_ips,
      COALESCE(dsnap.weekly_health_benefit_agency_paid, t.weekly_health_benefit_agency_paid) AS weekly_health_benefit_agency_paid,
      ((t.archived_at IS NULL OR t.archived_at > (p_week_end_date - 6)::timestamptz)
        AND COALESCE(t.start_date, p_week_end_date) <= p_week_end_date) AS in_week
    FROM public.team t
    LEFT JOIN public.weekly_cpr_reports rr ON rr.agency_id = p_agency_id AND rr.week_ending_date = p_week_end_date
    LEFT JOIN public.weekly_cpr_team_detail dsnap ON dsnap.weekly_cpr_report_id = rr.id AND dsnap.team_member_id = t.id
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND COALESCE(t.is_admin_backoffice, false) = false
      AND t.is_test_user IS NOT TRUE
      AND COALESCE(t.start_date, p_week_end_date) <= p_week_end_date
      AND (t.archived_at IS NULL OR t.archived_at > v_cycle_start::timestamptz)
  ),$q$, 1);

  -- Design-rate base fallback is prorated to the Monday-to-Friday workdays the person was employed.
  v_src := public.fn_source_replace_exact(v_src,
    $q$CASE WHEN pwp.wk_pay_type = 'SALARY' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * 40 ELSE 0 END) AS week_base_paid, LEAST(1.00, GREATEST(0, FLOOR((cw.week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS week_tenure_mult FROM roster r CROSS JOIN cycle_weeks cw JOIN per_week_pay pwp ON pwp.tm_id = r.id AND pwp.week_end_date = cw.week_end_date),$q$,
    $q$CASE WHEN pwp.wk_pay_type = 'SALARY' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * 40 * public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) ELSE 0 END) AS week_base_paid, public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) AS week_fraction, LEAST(1.00, GREATEST(0, FLOOR((cw.week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS week_tenure_mult FROM roster r CROSS JOIN cycle_weeks cw JOIN per_week_pay pwp ON pwp.tm_id = r.id AND pwp.week_end_date = cw.week_end_date),$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$base_qtd AS (SELECT tm_id, SUM(week_base_paid) AS qtd_base_paid, SUM(week_base_paid * week_tenure_mult) AS qtd_base_in_pool, SUM(week_base_paid * (1 - week_tenure_mult)) AS qtd_growth_budget FROM base_by_week GROUP BY tm_id),$q$,
    $q$base_qtd AS (SELECT tm_id, SUM(week_base_paid) AS qtd_base_paid, SUM(week_base_paid * week_tenure_mult) AS qtd_base_in_pool, SUM(week_base_paid * (1 - week_tenure_mult)) AS qtd_growth_budget, SUM(week_fraction) AS qtd_weeks_on_team FROM base_by_week GROUP BY tm_id),$q$, 1);

  -- Same proration for this week's not-yet-paid base.
  v_src := public.fn_source_replace_exact(v_src,
    $q$CASE WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 ELSE 0 END) AS actual_base_paid FROM roster r),$q$,
    $q$CASE WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * public.team_week_workday_fraction(r.start_date, r.end_date, p_week_end_date) WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * public.team_week_workday_fraction(r.start_date, r.end_date, p_week_end_date) ELSE 0 END) AS actual_base_paid FROM roster r),$q$, 1);

  -- Share inputs count only for people on the team this week; costs count for everyone on the roster.
  v_src := public.fn_source_replace_exact(v_src,
    $q$combined AS (SELECT r.id AS tm_id, r.first_name, r.last_name, r.r_role, r.r_role_category, r.r_role_level, r.pay_type, r.pay_rate, r.weekly_health_benefit_agency_paid, COALESCE(b.qtd_base_paid, 0) AS c_qtd_base_paid,$q$,
    $q$combined AS (SELECT r.id AS tm_id, r.in_week, r.first_name, r.last_name, r.r_role, r.r_role_category, r.r_role_level, r.pay_type, r.pay_rate, CASE WHEN r.in_week THEN r.weekly_health_benefit_agency_paid ELSE 0 END AS weekly_health_benefit_agency_paid, COALESCE(r.weekly_health_benefit_agency_paid, 0) * COALESCE(b.qtd_weeks_on_team, 0) AS c_health_qtd, COALESCE(b.qtd_base_paid, 0) AS c_qtd_base_paid,$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$COALESCE(a.current_week_qtd_sp, 0) AS c_curr_qtd_sp,$q$,
    $q$CASE WHEN r.in_week THEN COALESCE(a.current_week_qtd_sp, 0) ELSE 0 END AS c_curr_qtd_sp,$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$COALESCE(sr.avg_13wk, 0) AS c_avg_13wk, COALESCE(sr.avg_4wk, 0) AS c_avg_4wk,$q$,
    $q$CASE WHEN r.in_week THEN COALESCE(sr.avg_13wk, 0) ELSE 0 END AS c_avg_13wk, CASE WHEN r.in_week THEN COALESCE(sr.avg_4wk, 0) ELSE 0 END AS c_avg_4wk,$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$COALESCE(rpx.net_points, 0) AS c_net_points,$q$,
    $q$CASE WHEN r.in_week THEN COALESCE(rpx.net_points, 0) ELSE 0 END AS c_net_points,$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$COALESCE(wf.weighted_hours, 0) AS c_weighted_hours,$q$,
    $q$CASE WHEN r.in_week THEN COALESCE(wf.weighted_hours, 0) ELSE 0 END AS c_weighted_hours,$q$, 1);

  -- Health benefit cost = each person's weekly benefit x the weeks they were actually on the team this cycle.
  v_src := public.fn_source_replace_exact(v_src,
    $q$SUM(COALESCE(c.weekly_health_benefit_agency_paid, 0)) AS team_weekly_health, COALESCE(jsonb_agg(jsonb_build_object('team_member_id', c.tm_id, 'name', c.first_name || ' ' || c.last_name, 'weekly_health', COALESCE(c.weekly_health_benefit_agency_paid, 0)) ORDER BY c.first_name), '[]'::jsonb) AS per_person_health_detail FROM combined c),$q$,
    $q$SUM(COALESCE(c.weekly_health_benefit_agency_paid, 0)) AS team_weekly_health, SUM(c.c_health_qtd) AS qtd_health_total_exact, COALESCE(jsonb_agg(jsonb_build_object('team_member_id', c.tm_id, 'name', c.first_name || ' ' || c.last_name, 'weekly_health', COALESCE(c.weekly_health_benefit_agency_paid, 0)) ORDER BY c.first_name) FILTER (WHERE c.in_week), '[]'::jsonb) AS per_person_health_detail FROM combined c),$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$tt.team_weekly_health * v_week_of_cycle AS qtd_health_total, ((v_qtd_envelope - v_qtd_wc - (tt.team_weekly_health * v_week_of_cycle)) / (1.0 + v_burden_mult)$q$,
    $q$tt.qtd_health_total_exact AS qtd_health_total, ((v_qtd_envelope - v_qtd_wc - tt.qtd_health_total_exact) / (1.0 + v_burden_mult)$q$, 1);

  -- Only this week's team comes back out; departed teammates stay in the math but get no row.
  v_src := public.fn_source_replace_exact(v_src,
    $q$FROM settled s ORDER BY s.last_name;$q$,
    $q$FROM settled s WHERE s.in_week ORDER BY s.last_name;$q$, 1);

  -- Per-week accrual ledger (2026-09-06). Prior weeks read their own frozen carve-outs back
  -- out of that week's residual_pool_diag; only the current week is computed live. Before
  -- this, every QTD accrual was TODAY's weekly amount x weeks elapsed, so a roster change
  -- (a teammate leaving) repriced every prior week's carve and dropped the whole difference
  -- into this week's pool. Same defect class as the 2026-08-28 envelope fix (weekly_pool_lock).
  v_src := public.fn_source_replace_exact(v_src,
    $q$  v_qtd_hdb_max := v_weekly_hdb * v_week_of_cycle;$q$,
    $q$  SELECT COALESCE(SUM(CASE WHEN s.week_end_date = p_week_end_date THEN v_weekly_hdb
                           ELSE COALESCE((SELECT NULLIF(dd.residual_pool_diag->'carveouts_detail'->'health_development_bonus'->>'weekly_dollars', '')::numeric
                                            FROM public.weekly_cpr_team_detail dd
                                            JOIN public.weekly_cpr_reports rr2 ON rr2.id = dd.weekly_cpr_report_id
                                           WHERE rr2.agency_id = p_agency_id AND rr2.week_ending_date = s.week_end_date
                                             AND dd.residual_pool_diag ? 'carveouts_detail'
                                           ORDER BY dd.updated_at DESC LIMIT 1), v_weekly_hdb) END), 0)
    INTO v_qtd_hdb_max
    FROM public.team_comp_pool_schedule s
   WHERE s.agency_id = p_agency_id AND s.week_end_date >= v_cycle_start AND s.week_end_date <= p_week_end_date;$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$prize_wtq_qtd AS (SELECT v_weekly_prize_cart * v_week_of_cycle AS qtd_prize_cart, v_weekly_wtq_trip * v_week_of_cycle AS qtd_wtq_trip, v_weekly_goals_total * v_week_of_cycle AS qtd_goals_total, v_weekly_wtw_bonus * v_week_of_cycle AS qtd_wtw_bonus, v_weekly_gain_bonus * v_week_of_cycle AS qtd_gain_bonus, v_weekly_leaderboard_bonus * v_week_of_cycle AS qtd_leaderboard_bonus, v_weekly_all_star_bonus * v_week_of_cycle AS qtd_all_star_bonus, v_weekly_trailblazer_bonus * v_week_of_cycle AS qtd_trailblazer_bonus),$q$,
    $q$carve_by_week AS (
    /* Per-week accrual ledger (2026-09-06): each prior week's carve-outs come from that week's
       frozen residual_pool_diag; only the current week is live. No retroactive repricing when
       the roster changes. Falls back to the live carve for a week with no stored diag. */
    SELECT cw.week_end_date,
      CASE WHEN cw.week_end_date = p_week_end_date THEN v_carveouts_result
           ELSE COALESCE((SELECT dd.residual_pool_diag->'carveouts_detail'
                            FROM public.weekly_cpr_team_detail dd
                            JOIN public.weekly_cpr_reports rr2 ON rr2.id = dd.weekly_cpr_report_id
                           WHERE rr2.agency_id = p_agency_id AND rr2.week_ending_date = cw.week_end_date
                             AND dd.residual_pool_diag ? 'carveouts_detail'
                           ORDER BY dd.updated_at DESC LIMIT 1), v_carveouts_result)
      END AS cd
    FROM cycle_weeks cw),
  prize_wtq_qtd AS (SELECT
      COALESCE(SUM(COALESCE(NULLIF(cd->'mvp_prize_cart'->>'weekly_dollars', '')::numeric, 0)), 0) AS qtd_prize_cart,
      COALESCE(SUM(COALESCE(NULLIF(cd->'wtq_trip'->>'weekly_dollars', '')::numeric, 0)), 0) AS qtd_wtq_trip,
      COALESCE(SUM(COALESCE(NULLIF(cd->'goals_bonus_total'->>'weekly_dollars', '')::numeric, 0)), 0) AS qtd_goals_total,
      COALESCE(SUM(COALESCE(NULLIF(cd->'wtw_bonus'->>'weekly_dollars', '')::numeric, 0)), 0) AS qtd_wtw_bonus,
      COALESCE(SUM(COALESCE(NULLIF(cd->'gain_bonus'->>'weekly_dollars', '')::numeric, 0)), 0) AS qtd_gain_bonus,
      COALESCE(SUM(COALESCE(NULLIF(cd->'leaderboard_bonus'->>'weekly_dollars', '')::numeric, 0)), 0) AS qtd_leaderboard_bonus,
      COALESCE(SUM(COALESCE(NULLIF(cd->'all_star_bonus'->>'weekly_dollars', '')::numeric, 0)), 0) AS qtd_all_star_bonus,
      COALESCE(SUM(COALESCE(NULLIF(cd->'trailblazer_bonus'->>'weekly_dollars', '')::numeric, 0)), 0) AS qtd_trailblazer_bonus
    FROM carve_by_week),$q$, 1);

  EXECUTE v_src;

  ------------------------------------------------------------------------------------------
  -- compute_pool_carveouts + compute_warning_trigger: roster = on the team Monday morning of
  -- the week ('compensation' purpose as of week start), not is_active as of Saturday.
  ------------------------------------------------------------------------------------------
  v_src := pg_get_functiondef('public.compute_pool_carveouts(uuid, date)'::regprocedure);
  v_src := public.fn_source_replace_exact(v_src,
    $q$public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date)$q$,
    $q$public.get_expected_teammates(p_agency_id, 'compensation', p_week_end_date - 6)$q$, 6);
  EXECUTE v_src;

  v_src := pg_get_functiondef('public.compute_warning_trigger(uuid, date, numeric)'::regprocedure);
  v_src := public.fn_source_replace_exact(v_src,
    $q$public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date)$q$,
    $q$public.get_expected_teammates(p_agency_id, 'compensation', p_week_end_date - 6)$q$, 1);
  EXECUTE v_src;

  ------------------------------------------------------------------------------------------
  -- compose_weekly_cpr_html: digest Weekly Pay table keeps the snapshot rule only.
  ------------------------------------------------------------------------------------------
  v_src := pg_get_functiondef('public.compose_weekly_cpr_html(uuid, date)'::regprocedure);
  v_src := public.fn_source_replace_exact(v_src,
    $q$      AND t.category = 'agency'
      AND t.is_active = true
      AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz)$q$,
    $q$      AND t.category = 'agency'
      AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz)$q$, 1);
  EXECUTE v_src;
END
$do$;
