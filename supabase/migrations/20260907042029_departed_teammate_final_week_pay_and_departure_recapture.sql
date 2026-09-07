-- Departed teammate: final-week pay + departure recapture (Peter 2026-09-06).
--
-- 1. Someone terminated anywhere in the week (end_date <= that Saturday) is paid base for the days
--    worked plus commission, and nothing else: no share of the team bonus pool, no goals bonus,
--    no manager bonus, not eligible for MVP. Their sales points still count toward the team's
--    quarter-to-date total.
-- 2. Departure recapture. When a teammate leaves, the base that stops being charged to the pool is
--    not a windfall for the rest of the team. The agency holds back a share that mirrors the
--    new-hire growth budget in reverse: 100% of the freed base in the week they leave, easing
--    straight-line to 0 over 52 weeks (the tenure ramp phases a new hire's base INTO the pool over
--    52 weeks; this phases a departed base OUT). Only the part that was actually in the pool is
--    held back (x tenure_mult at departure). Sits in the waterfall exactly where base_in_pool
--    sits. Forward-only: departures with a last day on or after 2026-08-30.
--    Basis: gainsharing plans re-base on structural changes (headcount, capital) so the gain from
--    the change itself is not paid out as if the group earned it (Welbourne & Gomez-Mejia 1995,
--    J Management 21:559-609 review; Graham-Moore & Ross 1990, Gainsharing). The reverse ramp keeps
--    a seat swap (one leaves, one is hired) cost-neutral to the pool across the year.

DO $do$
DECLARE
  v_src text;
BEGIN
  ------------------------------------------------------------------------------------------
  -- compute_weekly_comp_residual_pool
  ------------------------------------------------------------------------------------------
  v_src := pg_get_functiondef('public.compute_weekly_comp_residual_pool(uuid, date)'::regprocedure);

  v_src := public.fn_source_replace_exact(v_src,
    $q$  v_reserve_rate CONSTANT numeric := 0.30; v_reserve_decay numeric;$q$,
    $q$  v_reserve_rate CONSTANT numeric := 0.30; v_reserve_decay numeric;
  v_recapture_from CONSTANT date := '2026-08-30';  -- departure recapture is forward-only (Peter 2026-09-06)$q$, 1);

  -- roster: left_in_week + shares_eligible flags; cost roster widened to a year so the recapture
  -- keeps easing out across quarters (everyone else's in-cycle costs are naturally zero).
  v_src := public.fn_source_replace_exact(v_src,
    $q$      ((t.archived_at IS NULL OR t.archived_at > (p_week_end_date - 6)::timestamptz)
        AND COALESCE(t.start_date, p_week_end_date) <= p_week_end_date) AS in_week
    FROM public.team t$q$,
    $q$      ((t.archived_at IS NULL OR t.archived_at > (p_week_end_date - 6)::timestamptz)
        AND COALESCE(t.start_date, p_week_end_date) <= p_week_end_date) AS in_week,
      /* terminated anywhere in the week (end_date <= that Saturday, Peter 2026-09-02 bar):
         paid base for days worked + commission only. No pool share, goals, manager bonus, MVP. */
      (COALESCE(t.end_date, dsnap.end_date, (t.archived_at AT TIME ZONE 'America/Chicago')::date) IS NOT NULL
        AND COALESCE(t.end_date, dsnap.end_date, (t.archived_at AT TIME ZONE 'America/Chicago')::date) <= p_week_end_date) AS left_in_week,
      (((t.archived_at IS NULL OR t.archived_at > (p_week_end_date - 6)::timestamptz)
        AND COALESCE(t.start_date, p_week_end_date) <= p_week_end_date)
       AND NOT (COALESCE(t.end_date, dsnap.end_date, (t.archived_at AT TIME ZONE 'America/Chicago')::date) IS NOT NULL
        AND COALESCE(t.end_date, dsnap.end_date, (t.archived_at AT TIME ZONE 'America/Chicago')::date) <= p_week_end_date)) AS shares_eligible
    FROM public.team t$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$      AND (t.archived_at IS NULL OR t.archived_at > v_cycle_start::timestamptz)
  ),$q$,
    $q$      AND (t.archived_at IS NULL OR t.archived_at > (v_cycle_start - 364)::timestamptz)
  ),$q$, 1);

  -- pool shares only for people still on the team at week end
  v_src := public.fn_source_replace_exact(v_src,
    $q$combined AS (SELECT r.id AS tm_id, r.in_week, r.first_name,$q$,
    $q$combined AS (SELECT r.id AS tm_id, r.in_week, r.left_in_week, r.shares_eligible, r.first_name,$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$CASE WHEN r.in_week THEN COALESCE(sr.avg_13wk, 0) ELSE 0 END AS c_avg_13wk, CASE WHEN r.in_week THEN COALESCE(sr.avg_4wk, 0) ELSE 0 END AS c_avg_4wk,$q$,
    $q$CASE WHEN r.shares_eligible THEN COALESCE(sr.avg_13wk, 0) ELSE 0 END AS c_avg_13wk, CASE WHEN r.shares_eligible THEN COALESCE(sr.avg_4wk, 0) ELSE 0 END AS c_avg_4wk,$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$CASE WHEN r.in_week THEN COALESCE(rpx.net_points, 0) ELSE 0 END AS c_net_points,$q$,
    $q$CASE WHEN r.shares_eligible THEN COALESCE(rpx.net_points, 0) ELSE 0 END AS c_net_points,$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$CASE WHEN r.in_week THEN COALESCE(wf.weighted_hours, 0) ELSE 0 END AS c_weighted_hours,$q$,
    $q$CASE WHEN r.shares_eligible THEN COALESCE(wf.weighted_hours, 0) ELSE 0 END AS c_weighted_hours,$q$, 1);

  -- departure recapture in the waterfall, right where base_in_pool sits
  v_src := public.fn_source_replace_exact(v_src,
    $q$pool_calc_pre AS (SELECT tt.*, pwq.*, v_qtd_envelope AS qtd_envelope, v_qtd_wc AS qtd_wc, tt.qtd_health_total_exact AS qtd_health_total, ((v_qtd_envelope - v_qtd_wc - tt.qtd_health_total_exact) / (1.0 + v_burden_mult) - tt.qtd_base_in_pool_total - (CASE WHEN v_accrual_applies THEN v_comm_charge ELSE tt.qtd_comm_total END)$q$,
    $q$departure_recapture AS (
    /* Departure recapture (Peter 2026-09-06). Freed base of a teammate who left is held back from
       the pool: design base x uncovered Mon-Fri workdays x tenure_mult at departure, easing
       straight-line to 0 over 52 weeks. The new-hire growth budget in reverse. Forward-only. */
    SELECT COALESCE(SUM(
      (CASE WHEN r.pay_type = 'SALARY' THEN r.pay_rate WHEN r.pay_type = 'HOURLY' THEN r.pay_rate * 40 ELSE 0 END)
      * (1 - public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date))
      * LEAST(1.00, GREATEST(0, FLOOR((r.end_date - COALESCE(r.start_date, r.end_date))::numeric / 7.0) / 52.0))
      * GREATEST(0, 1 - FLOOR((cw.week_end_date - r.end_date)::numeric / 7.0) / 52.0)
    ), 0) AS qtd_departure_recapture
    FROM roster r CROSS JOIN cycle_weeks cw
    WHERE r.end_date IS NOT NULL AND r.end_date >= v_recapture_from AND r.end_date < cw.week_end_date AND r.pay_rate IS NOT NULL),
  pool_calc_pre AS (SELECT tt.*, pwq.*, dr.qtd_departure_recapture, v_qtd_envelope AS qtd_envelope, v_qtd_wc AS qtd_wc, tt.qtd_health_total_exact AS qtd_health_total, ((v_qtd_envelope - v_qtd_wc - tt.qtd_health_total_exact) / (1.0 + v_burden_mult) - tt.qtd_base_in_pool_total - dr.qtd_departure_recapture - (CASE WHEN v_accrual_applies THEN v_comm_charge ELSE tt.qtd_comm_total END)$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$AS pre_reserve_pool_raw FROM team_totals tt CROSS JOIN prize_wtq_qtd pwq),$q$,
    $q$AS pre_reserve_pool_raw FROM team_totals tt CROSS JOIN prize_wtq_qtd pwq CROSS JOIN departure_recapture dr),$q$, 1);

  -- diagnostics
  v_src := public.fn_source_replace_exact(v_src,
    $q$        'qtd_base_in_pool', ROUND(s.qtd_base_in_pool_total, 2),
        'qtd_actual_base_paid', ROUND(s.qtd_base_paid_total, 2),
        'qtd_actual_base_source'$q$,
    $q$        'qtd_base_in_pool', ROUND(s.qtd_base_in_pool_total, 2),
        'qtd_departure_recapture', ROUND(s.qtd_departure_recapture, 2),
        'qtd_departure_recapture_source', 'freed base of a teammate who left (design base x uncovered workdays x tenure_mult at departure) held back from the pool, easing straight-line to 0 over 52 weeks; the new-hire growth budget in reverse; forward-only from 2026-08-30 departures',
        'qtd_actual_base_paid', ROUND(s.qtd_base_paid_total, 2),
        'qtd_actual_base_source'$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$'qtd_burden', ROUND((s.qtd_base_in_pool_total + s.qtd_comm_total$q$,
    $q$'qtd_burden', ROUND((s.qtd_base_in_pool_total + s.qtd_departure_recapture + s.qtd_comm_total$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$      'person_pay_type', s.pay_type,$q$,
    $q$      'departed_this_week', s.left_in_week, 'shares_eligible', s.shares_eligible,
      'person_pay_type', s.pay_type,$q$, 1);

  EXECUTE v_src;

  ------------------------------------------------------------------------------------------
  -- write_weekly_comp_v2: no manager bonus, no goals bonus, no MVP for someone who left this week
  ------------------------------------------------------------------------------------------
  v_src := pg_get_functiondef('public.write_weekly_comp_v2(uuid, date)'::regprocedure);

  v_src := public.fn_source_replace_exact(v_src,
    $q$        manager_bonus = COALESCE((SELECT (mgr->>'weekly_bonus_dollars')::numeric FROM jsonb_array_elements(COALESCE(s.diagnostics->'carveouts_detail'->'manager_bonus'->'detail', '[]'::jsonb)) mgr WHERE mgr->>'team_member_id' = wctd.team_member_id::text LIMIT 1), 0),$q$,
    $q$        manager_bonus = CASE WHEN COALESCE((s.diagnostics->>'departed_this_week')::boolean, false) THEN 0
                             ELSE COALESCE((SELECT (mgr->>'weekly_bonus_dollars')::numeric FROM jsonb_array_elements(COALESCE(s.diagnostics->'carveouts_detail'->'manager_bonus'->'detail', '[]'::jsonb)) mgr WHERE mgr->>'team_member_id' = wctd.team_member_id::text LIMIT 1), 0) END,$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$    with_dollars AS (SELECT p.*, (10 * (p.as_hits + p.tb_hits + p.leaderboard_hits + CASE WHEN p.gain_hit THEN 1 ELSE 0 END + CASE WHEN p.won_the_week THEN 1 ELSE 0 END))::numeric AS dollars FROM per_person p),$q$,
    $q$    with_dollars AS (SELECT p.*,
      /* terminated anywhere in the week: no goals bonus (Peter 2026-09-06) */
      (CASE WHEN EXISTS (SELECT 1 FROM public.team tx WHERE tx.id = p.team_member_id AND tx.end_date IS NOT NULL AND tx.end_date <= p_week_end_date) THEN 0 ELSE 10 END
       * (p.as_hits + p.tb_hits + p.leaderboard_hits + CASE WHEN p.gain_hit THEN 1 ELSE 0 END + CASE WHEN p.won_the_week THEN 1 ELSE 0 END))::numeric AS dollars FROM per_person p),$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$      WITH curr AS (SELECT d.team_member_id, d.sales_points AS curr_qtd FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report_id AND d.sales_points IS NOT NULL),$q$,
    $q$      WITH curr AS (SELECT d.team_member_id, d.sales_points AS curr_qtd FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report_id AND d.sales_points IS NOT NULL
        /* terminated anywhere in the week: not eligible for MVP (Peter 2026-09-06) */
        AND NOT EXISTS (SELECT 1 FROM public.team tx WHERE tx.id = d.team_member_id AND tx.end_date IS NOT NULL AND tx.end_date <= p_week_end_date)),$q$, 1);

  EXECUTE v_src;
END
$do$;
