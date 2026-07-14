-- 20260714_purge_podium_terminology.sql
-- Peter directive follow-up 2026-07-14: purge remaining live "podium" refs.
-- Rename in-function variables + return keys + user-visible formula strings.
-- No semantic change; string/name-only edits.
--
-- Three functions touched:
--   1. compute_pool_carveouts        — user-visible formula string
--   2. audit_weekly_leaderboard_crossings — internal var, comment, JSON return key
--   3. write_weekly_comp_v2          — remove stale rename-comment
--
-- Post-migration: refresh residual_pool_diag on current in-progress week
-- and surgical JSONB update on the one historical (2026-07-11) frozen row.

-- ─────────────────────────────────────────────────────────────────
-- 1) compute_pool_carveouts — only change is leaderboard_bonus.formula string
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.compute_pool_carveouts(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_pool_result         jsonb;
  v_annual_ot_smvc      numeric;
  v_annual_ot_scorecard numeric;
  v_annual_ot_basis     numeric;

  v_annual_manager_bonus numeric := 0;
  v_manager_detail      jsonb := '[]'::jsonb;

  v_annual_life_ins     numeric := 0;
  v_life_ins_detail     jsonb := '[]'::jsonb;

  v_annual_apparel      numeric := 0;
  v_apparel_detail      jsonb := '[]'::jsonb;

  v_annual_hdb          numeric := 0;
  v_hdb_detail          jsonb := '[]'::jsonb;

  v_annual_cc           numeric := 0;
  v_cc_pct              CONSTANT numeric := 0.03;

  v_curr_cycle          record;
  v_curr_cycle_start    date;
  v_curr_cycle_end      date;
  v_prior_cycle_start   date;
  v_prior_cycle_end     date;
  v_week_of_cycle       int;
  v_curr_qtr_wins       int := 0;
  v_prior_qtr_wins      int := 0;
  v_weeks_remaining     int;
  v_projected_wins      int;

  v_rate                CONSTANT numeric := 0.01;
  v_pace                numeric := 0;
  v_pool_pace_dollars   numeric := 0;

  v_quarterly_mvp       numeric := 0;
  v_quarterly_wtq       numeric := 0;
  v_wtq_halted          boolean := false;
  v_wtq_halt_reason     text := NULL;

  v_mvp_share_pct       CONSTANT numeric := 0.50;
  v_rest_share_pct      CONSTANT numeric := 0.50;
  v_team_count          int := 0;
  v_rest_count          int := 0;
  v_mvp_dollars         numeric := 0;
  v_rest_pool_dollars   numeric := 0;
  v_rest_per_person     numeric := 0;

  v_leaderboard_categories CONSTANT int := 4;
  v_leaderboard_slots      CONSTANT int := 3;
  v_annual_wtw_bonus         numeric := 0;
  v_annual_gain_bonus        numeric := 0;
  v_annual_leaderboard_bonus numeric := 0;
  v_annual_all_star_bonus    numeric := 0;
  v_annual_trailblazer_bonus numeric := 0;
  v_annual_goals_total       numeric := 0;

  v_total_carveouts_annual numeric;
BEGIN
  v_pool_result         := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_annual_ot_smvc      := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_smvc_dollars','')::numeric, 0);
  v_annual_ot_scorecard := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_scorecard_dollars','')::numeric, 0);
  v_annual_ot_basis     := v_annual_ot_smvc + v_annual_ot_scorecard;

  SELECT
    COALESCE(SUM(
      CASE et.role_level
        WHEN 'Unit Manager'    THEN 0.001
        WHEN 'Section Manager' THEN 0.002
        WHEN 'Office Manager'  THEN 0.003
        ELSE 0
      END * 52.0 * v_annual_ot_scorecard
    ), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', et.team_id,
      'name', et.first_name || ' ' || et.last_name,
      'role_level', et.role_level,
      'weekly_rate_pct', CASE et.role_level
                          WHEN 'Unit Manager'    THEN 0.1
                          WHEN 'Section Manager' THEN 0.2
                          WHEN 'Office Manager'  THEN 0.3
                          ELSE 0 END,
      'weekly_bonus_dollars', ROUND(
        CASE et.role_level
          WHEN 'Unit Manager'    THEN 0.001
          WHEN 'Section Manager' THEN 0.002
          WHEN 'Office Manager'  THEN 0.003
          ELSE 0 END * v_annual_ot_scorecard, 2),
      'annual_bonus_dollars', ROUND(
        CASE et.role_level
          WHEN 'Unit Manager'    THEN 0.001
          WHEN 'Section Manager' THEN 0.002
          WHEN 'Office Manager'  THEN 0.003
          ELSE 0 END * v_annual_ot_scorecard * 52.0, 2)
    )), '[]'::jsonb)
  INTO v_annual_manager_bonus, v_manager_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  WHERE et.role_level IN ('Unit Manager','Section Manager','Office Manager');

  SELECT
    COALESCE(SUM(m.monthly_cap * 12.0), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id',   et.team_id,
      'name',             et.first_name || ' ' || et.last_name,
      'start_date',       et.start_date,
      'year_of_employment', m.yoe,
      'monthly_cap_dollars', m.monthly_cap,
      'annual_dollars',    ROUND(m.monthly_cap * 12.0, 2)
    )), '[]'::jsonb)
  INTO v_annual_life_ins, v_life_ins_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  CROSS JOIN LATERAL (
    SELECT GREATEST(1, FLOOR((p_week_end_date - et.start_date)::numeric / 365.25)::int + 1) AS yoe
  ) yc
  CROSS JOIN LATERAL (
    SELECT
      yc.yoe,
      CASE
        WHEN yc.yoe = 1  THEN 50   WHEN yc.yoe = 2  THEN 100
        WHEN yc.yoe = 3  THEN 150  WHEN yc.yoe = 4  THEN 200
        WHEN yc.yoe = 5  THEN 250  WHEN yc.yoe = 6  THEN 300
        WHEN yc.yoe = 7  THEN 350  WHEN yc.yoe = 8  THEN 400
        WHEN yc.yoe = 9  THEN 450  WHEN yc.yoe = 10 THEN 475
        ELSE 500
      END AS monthly_cap
  ) m
  WHERE et.start_date IS NOT NULL;

  SELECT
    COALESCE(SUM(m.annual_apparel), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id',   et.team_id,
      'name',             et.first_name || ' ' || et.last_name,
      'start_date',       et.start_date,
      'year_of_employment', m.yoe,
      'annual_dollars',    ROUND(m.annual_apparel, 2)
    )), '[]'::jsonb)
  INTO v_annual_apparel, v_apparel_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  CROSS JOIN LATERAL (
    SELECT GREATEST(1, FLOOR((p_week_end_date - et.start_date)::numeric / 365.25)::int + 1) AS yoe
  ) yc
  CROSS JOIN LATERAL (
    SELECT yc.yoe, CASE WHEN yc.yoe = 1 THEN 200 ELSE 100 END AS annual_apparel
  ) m
  WHERE et.start_date IS NOT NULL;

  SELECT
    COALESCE(SUM(25 * 52.0), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id',     et.team_id,
      'name',               et.first_name || ' ' || et.last_name,
      'weekly_max_dollars', 25,
      'annual_max_dollars', 1300
    )), '[]'::jsonb)
  INTO v_annual_hdb, v_hdb_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et;

  v_annual_cc := v_cc_pct * v_annual_ot_basis;

  SELECT * INTO v_curr_cycle FROM public.current_cycle_info(p_agency_id, p_week_end_date);
  v_curr_cycle_start  := v_curr_cycle.cycle_start;
  v_curr_cycle_end    := v_curr_cycle.cycle_end;
  v_week_of_cycle     := v_curr_cycle.week_of_cycle;
  v_prior_cycle_start := (v_curr_cycle_start - INTERVAL '91 days')::date;
  v_prior_cycle_end   := (v_curr_cycle_start - INTERVAL '1 day')::date;

  SELECT COUNT(*) INTO v_curr_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date >= v_curr_cycle_start
    AND week_ending_date <= LEAST(v_curr_cycle_end, p_week_end_date)
    AND won_the_week = true;

  SELECT COUNT(*) INTO v_prior_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date >= v_prior_cycle_start
    AND week_ending_date <= v_prior_cycle_end
    AND won_the_week = true;

  v_weeks_remaining := GREATEST(0, 13 - v_week_of_cycle);
  v_projected_wins  := v_curr_qtr_wins + v_weeks_remaining;
  v_pace := LEAST(1.0, v_projected_wins::numeric / 13.0);
  v_pool_pace_dollars := v_rate * v_annual_ot_basis * v_pace;

  IF v_projected_wins < 9 THEN
    v_quarterly_wtq   := 0;
    v_wtq_halted      := true;
    v_wtq_halt_reason := format(
      'projected_wins (%s) < 9 floor. actual %s wins so far, %s weeks remaining, assuming all remaining win.',
      v_projected_wins, v_curr_qtr_wins, v_weeks_remaining
    );
  ELSE
    v_quarterly_wtq := v_pool_pace_dollars;
  END IF;

  v_quarterly_mvp := v_pool_pace_dollars;

  SELECT COUNT(*) INTO v_team_count
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date);
  v_rest_count        := GREATEST(0, v_team_count - 1);
  v_mvp_dollars       := v_quarterly_wtq * v_mvp_share_pct;
  v_rest_pool_dollars := v_quarterly_wtq * v_rest_share_pct;
  v_rest_per_person   := CASE
    WHEN v_rest_count > 0 THEN v_rest_pool_dollars / v_rest_count::numeric
    ELSE 0
  END;

  v_annual_wtw_bonus         := 10 * v_team_count * 52;
  v_annual_gain_bonus        := 10 * v_team_count * 52;
  v_annual_leaderboard_bonus := 10 * v_leaderboard_slots * v_leaderboard_categories * 52;
  v_annual_all_star_bonus    := 10 * v_leaderboard_categories * v_team_count * 52;
  v_annual_trailblazer_bonus := 10 * v_leaderboard_categories * 1 * 52;
  v_annual_goals_total       := v_annual_wtw_bonus + v_annual_gain_bonus
                              + v_annual_leaderboard_bonus + v_annual_all_star_bonus
                              + v_annual_trailblazer_bonus;

  v_total_carveouts_annual := v_annual_manager_bonus
                    + v_annual_life_ins
                    + v_annual_apparel
                    + v_annual_hdb
                    + v_annual_cc
                    + (v_quarterly_mvp * 4.0)
                    + (v_quarterly_wtq * 4.0)
                    + v_annual_goals_total;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'week_end_date', p_week_end_date,
    'design_note', 'Carve-and-forget: unearned carveouts stay with agency. MVP+WtQ pots are QUARTERLY, restock each quarter. Goals-bonus carveouts (WtW/Gain/Leaderboard/All-Star/Trailblazer) added 2026-07-14 as structural max - pre-subtracted from pool, paid when earned, forfeited to agency when not.',
    'inputs', jsonb_build_object(
      'annual_ot_smvc',              ROUND(v_annual_ot_smvc, 2),
      'annual_ot_scorecard',         ROUND(v_annual_ot_scorecard, 2),
      'annual_ot_basis',             ROUND(v_annual_ot_basis, 2),
      'team_count',                  v_team_count,
      'leaderboard_categories',      v_leaderboard_categories,
      'leaderboard_slots',           v_leaderboard_slots,
      'current_cycle_start',         v_curr_cycle_start,
      'current_cycle_end',           v_curr_cycle_end,
      'week_of_cycle',               v_week_of_cycle,
      'current_cycle_wins_to_date',  v_curr_qtr_wins,
      'weeks_remaining',             v_weeks_remaining,
      'projected_wins',              v_projected_wins,
      'prior_cycle_start',           v_prior_cycle_start,
      'prior_cycle_end',             v_prior_cycle_end,
      'prior_cycle_wins',            v_prior_qtr_wins,
      'on_time_pace',                ROUND(v_pace, 4),
      'pace_formula',                'LEAST(1.0, (curr_wins + weeks_remaining) / 13.0) - assumes all remaining weeks win'
    ),
    'manager_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_manager_bonus, 2),
      'weekly_dollars', ROUND(v_annual_manager_bonus / 52.0, 2),
      'formula',        'sum(role_level_pct x on-time Scorecard annual): UM=0.1%, SectM=0.2%, OM=0.3%',
      'detail',         v_manager_detail
    ),
    'life_insurance_stipend', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_life_ins, 2),
      'weekly_dollars', ROUND(v_annual_life_ins / 52.0, 2),
      'formula',        'sum(monthly_cap_by_year_of_employment x 12) across active non-owner roster',
      'detail',         v_life_ins_detail
    ),
    'apparel', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_apparel, 2),
      'weekly_dollars', ROUND(v_annual_apparel / 52.0, 2),
      'formula',        'Y1 = $200 (13-week + first anniversary), Y2+ = $100 (annual anniversary)',
      'detail',         v_apparel_detail
    ),
    'health_development_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_hdb, 2),
      'weekly_dollars', ROUND(v_annual_hdb / 52.0, 2),
      'formula',        '$25/week x 52 weeks per active non-owner team member (structural max)',
      'detail',         v_hdb_detail
    ),
    'champions_circle', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_cc, 2),
      'weekly_dollars', ROUND(v_annual_cc / 52.0, 2),
      'pct_of_basis',   v_cc_pct,
      'formula',        '3% x on-time (SMVC + Scorecard) annual basis, flat accrual'
    ),
    'mvp_prize_cart', jsonb_build_object(
      'quarterly_dollars', ROUND(v_quarterly_mvp, 2),
      'annual_dollars',    ROUND(v_quarterly_mvp * 4.0, 2),
      'weekly_dollars',    ROUND(v_quarterly_mvp / 13.0, 2),
      'formula',           '1% x on-time (SMVC + Scorecard) x projected_wins/13 - QUARTERLY pot; weekly accrual = quarterly / 13',
      'rate_pct',          v_rate,
      'pace',              ROUND(v_pace, 4),
      'projected_wins',    v_projected_wins,
      'note',              'Same formula as WtQ Trip. Restocks each quarter. Weekly accrual reserves 1/13 of the quarter''s pot.'
    ),
    'wtq_trip', jsonb_build_object(
      'quarterly_dollars', ROUND(v_quarterly_wtq, 2),
      'annual_dollars',    ROUND(v_quarterly_wtq * 4.0, 2),
      'weekly_dollars',    ROUND(v_quarterly_wtq / 13.0, 2),
      'formula',           '1% x on-time (SMVC + Scorecard) x projected_wins/13 - QUARTERLY pot; weekly accrual = quarterly / 13',
      'rate_pct',          v_rate,
      'pace',              ROUND(v_pace, 4),
      'projected_wins',    v_projected_wins,
      'floor_wins',        9,
      'halted',            v_wtq_halted,
      'halt_reason',       v_wtq_halt_reason,
      'note',              'Same formula as MVP Prize Cart. QUARTERLY pot. Halts to $0 if projected total wins < 9-wins floor.',
      'mvp_share_pct',           v_mvp_share_pct,
      'rest_share_pct',          v_rest_share_pct,
      'rest_split_rule',         'evenly per non-MVP teammate (MVP does NOT receive share of the rest pool)',
      'team_count',              v_team_count,
      'rest_of_team_count',      v_rest_count,
      'mvp_dollars',             ROUND(v_mvp_dollars, 2),
      'rest_pool_dollars',       ROUND(v_rest_pool_dollars, 2),
      'rest_per_person_dollars', ROUND(v_rest_per_person, 2)
    ),
    'wtw_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_wtw_bonus, 2),
      'weekly_dollars', ROUND(v_annual_wtw_bonus / 52.0, 2),
      'formula',        '$10 x team_count x 52 weeks (structural max: whole team wins every week). Carve-and-forget: unearned stays with agency.'
    ),
    'gain_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_gain_bonus, 2),
      'weekly_dollars', ROUND(v_annual_gain_bonus / 52.0, 2),
      'formula',        '$10 x team_count x 52 weeks (structural max: everyone hits 1% Gain every week). Carve-and-forget: unearned stays with agency.'
    ),
    'leaderboard_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_leaderboard_bonus, 2),
      'weekly_dollars', ROUND(v_annual_leaderboard_bonus / 52.0, 2),
      'formula',        '$10 x 3 leaderboard slots x 4 categories x 52 weeks (structural max: all leaderboard slots earned in every category every week). Carve-and-forget.'
    ),
    'all_star_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_all_star_bonus, 2),
      'weekly_dollars', ROUND(v_annual_all_star_bonus / 52.0, 2),
      'formula',        '$10 x 4 categories x team_count x 52 weeks (structural max: everyone crosses an All-Star in every category every week). Carve-and-forget.'
    ),
    'trailblazer_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_trailblazer_bonus, 2),
      'weekly_dollars', ROUND(v_annual_trailblazer_bonus / 52.0, 2),
      'formula',        '$10 x 4 categories x 1 person x 52 weeks (structural max: one Trailblazer crossing per category per week). Carve-and-forget.'
    ),
    'goals_bonus_total', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_goals_total, 2),
      'weekly_dollars', ROUND(v_annual_goals_total / 52.0, 2),
      'note',           'Sum of WtW + Gain + Leaderboard + All-Star + Trailblazer max carveouts'
    ),
    'total_annual_carveouts', ROUND(v_total_carveouts_annual, 2),
    'total_weekly_carveouts', ROUND(v_total_carveouts_annual / 52.0, 2),
    'computed_at', now()
  );
END;
$function$;

-- ─────────────────────────────────────────────────────────────────
-- 2) audit_weekly_leaderboard_crossings — internal var/comment/JSON key rename
--    v_podium_updates → v_leaderboard_updates (4 uses)
--    "sales podiums" → "sales leaderboards" (comment)
--    'podium_updates_this_run' → 'leaderboard_updates_this_run' (return JSON key)
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.audit_weekly_leaderboard_crossings(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cycle_end          date;
  v_quarter_start      date;
  v_is_quarter_close   boolean;
  v_report_id          uuid;
  v_all_star_hits      int := 0;
  v_trailblazer_hits   int := 0;
  v_leaderboard_updates int := 0;
  v_cat_result         jsonb := '[]'::jsonb;
  r                    record;
  cfg                  record;
  bronze_val           numeric;
  gold_val             numeric;
  floor_val            numeric;
  trailblazer_thresh   numeric;
  crossed              boolean;
  new_gold             boolean;
  period_lbl           text;
BEGIN
  v_cycle_end        := (public.current_cycle_info(p_agency_id, p_week_end_date)).cycle_end;
  v_is_quarter_close := (v_cycle_end = p_week_end_date);
  v_quarter_start    := date_trunc('quarter', p_week_end_date::timestamp)::date;

  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object(
      'error', 'no weekly_cpr_reports row for week',
      'agency_id', p_agency_id, 'week_end_date', p_week_end_date
    );
  END IF;

  FOR cfg IN
    SELECT category, round_step
    FROM public.leaderboard_floor_config
    ORDER BY category
  LOOP
    IF cfg.category = 'quarter_sp' AND NOT v_is_quarter_close THEN
      CONTINUE;
    END IF;

    SELECT record_value INTO bronze_val FROM public.leaderboards
      WHERE agency_id = p_agency_id AND category = cfg.category AND tier = 3;
    SELECT record_value INTO gold_val FROM public.leaderboards
      WHERE agency_id = p_agency_id AND category = cfg.category AND tier = 1;

    floor_val := COALESCE(FLOOR(bronze_val / cfg.round_step) * cfg.round_step, 0);
    trailblazer_thresh := COALESCE(CEIL((gold_val + 0.01) / cfg.round_step) * cfg.round_step, 0);

    FOR r IN
      SELECT
        t.id AS team_member_id,
        t.first_name,
        CASE cfg.category
          WHEN 'week_quotes' THEN
            COALESCE(
              (SELECT req.net_quotes
                 FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_end_date) req
                WHERE req.team_member_id = t.id
                LIMIT 1),
              0)::numeric
          WHEN 'week_sp' THEN
            GREATEST(0,
              COALESCE(d.sales_points, 0)::numeric
              - COALESCE(
                  (SELECT d2.sales_points
                     FROM public.weekly_cpr_team_detail d2
                     JOIN public.weekly_cpr_reports r2 ON r2.id = d2.weekly_cpr_report_id
                    WHERE r2.agency_id = p_agency_id
                      AND d2.team_member_id = t.id
                      AND r2.week_ending_date < p_week_end_date
                      AND r2.week_ending_date >= v_quarter_start
                    ORDER BY r2.week_ending_date DESC
                    LIMIT 1),
                  0)::numeric
            )
          WHEN 'four_week_sp' THEN
            public.compute_rolling_4wk_sp(p_agency_id, p_week_end_date, t.id)
          WHEN 'quarter_sp' THEN COALESCE(
            (SELECT SUM(d2.sales_points)
              FROM public.weekly_cpr_team_detail d2
              JOIN public.weekly_cpr_reports r2 ON r2.id = d2.weekly_cpr_report_id
              WHERE r2.agency_id = p_agency_id
                AND d2.team_member_id = t.id
                AND r2.week_ending_date > (v_cycle_end - INTERVAL '13 weeks')::date
                AND r2.week_ending_date <= v_cycle_end
            ), 0)::numeric
        END AS the_value
      FROM public.team t
      LEFT JOIN public.weekly_cpr_team_detail d
        ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report_id
      WHERE t.agency_id = p_agency_id
        AND t.is_active = true
        AND t.archived_at IS NULL
        AND t.is_admin_backoffice = false
        AND (t.is_test_user IS NOT TRUE)
        -- INTENTIONALLY: no role_category filter. Peter directive 2026-07-12 pm4:
        -- retention teammates (Cassie, Stephanie) belong on sales leaderboards like anyone else.
    LOOP
      crossed := (r.the_value >= floor_val AND floor_val > 0);
      new_gold := (r.the_value > COALESCE(gold_val, 0));

      IF cfg.category = 'quarter_sp' THEN
        period_lbl := 'Q' || EXTRACT(quarter FROM v_cycle_end)::text || ' ' || EXTRACT(year FROM v_cycle_end)::text;
      ELSE
        period_lbl := to_char(p_week_end_date, 'Mon DD, YYYY');
      END IF;

      IF crossed THEN
        WITH ins AS (
          INSERT INTO public.all_star_crossings
            (agency_id, team_member_id, category, week_ending, value_at_crossing, floor_at_crossing)
          VALUES (p_agency_id, r.team_member_id, cfg.category, p_week_end_date, r.the_value, floor_val)
          ON CONFLICT (agency_id, team_member_id, category, week_ending) DO NOTHING
          RETURNING 1
        )
        SELECT COUNT(*) INTO v_all_star_hits FROM (
          SELECT v_all_star_hits + (SELECT COUNT(*) FROM ins) AS x
        ) s;

        IF EXISTS (
          SELECT 1 FROM public.all_star_crossings
          WHERE agency_id = p_agency_id AND team_member_id = r.team_member_id
            AND category = cfg.category AND week_ending = p_week_end_date
            AND created_at >= now() - INTERVAL '1 minute'
        ) THEN
          INSERT INTO public.all_star_counts (agency_id, category, team_member_id, count, seeded_count, last_crossing_at, updated_at)
          VALUES (p_agency_id, cfg.category, r.team_member_id, 1, 0, now(), now())
          ON CONFLICT (agency_id, category, team_member_id) DO UPDATE
            SET count = public.all_star_counts.count + 1,
                last_crossing_at = now(),
                updated_at = now();
        END IF;
      END IF;

      IF trailblazer_thresh > 0 AND r.the_value >= trailblazer_thresh THEN
        -- Column names updated 2026-07-12: crossing_value → value_at_crossing,
        -- threshold_at_crossing → floor_at_crossing (align with all_star_crossings shape).
        INSERT INTO public.trailblazer_crossings
          (agency_id, category, team_member_id, value_at_crossing, floor_at_crossing, period_label, week_ending)
        VALUES (p_agency_id, cfg.category, r.team_member_id, r.the_value, trailblazer_thresh, period_lbl, p_week_end_date)
        ON CONFLICT DO NOTHING;
        v_trailblazer_hits := v_trailblazer_hits + 1;
      END IF;

      IF r.the_value > COALESCE(bronze_val, 0) THEN
        IF NOT EXISTS (
          SELECT 1 FROM public.leaderboards
          WHERE agency_id = p_agency_id AND category = cfg.category
            AND team_member_id = r.team_member_id
            AND record_period_label = period_lbl
        ) THEN
          WITH combined AS (
            SELECT team_member_id, record_value, record_period_label, record_week_ending, set_at, notes
            FROM public.leaderboards
            WHERE agency_id = p_agency_id AND category = cfg.category
            UNION ALL
            SELECT r.team_member_id, r.the_value, period_lbl,
              CASE WHEN cfg.category = 'quarter_sp' THEN NULL ELSE p_week_end_date END,
              now(),
              NULL
          ),
          ranked AS (
            SELECT *, ROW_NUMBER() OVER (ORDER BY record_value DESC, set_at DESC) AS rn
            FROM combined
          )
          , wiped AS (
            DELETE FROM public.leaderboards
            WHERE agency_id = p_agency_id AND category = cfg.category
            RETURNING 1
          ),
          reinserted AS (
            INSERT INTO public.leaderboards
              (agency_id, category, tier, team_member_id, record_value, record_period_label, record_week_ending, set_at, notes)
            SELECT p_agency_id, cfg.category, rn, team_member_id, record_value,
                   record_period_label, record_week_ending, set_at, notes
            FROM ranked
            WHERE rn <= 3
              AND (SELECT COUNT(*) FROM wiped) >= 0
            RETURNING 1
          )
          SELECT COUNT(*) INTO v_leaderboard_updates FROM (
            SELECT v_leaderboard_updates + (SELECT COUNT(*) FROM reinserted) AS x
          ) s;
        END IF;
      END IF;
    END LOOP;

    v_cat_result := v_cat_result || jsonb_build_object(
      'category', cfg.category,
      'floor', floor_val,
      'trailblazer_threshold', trailblazer_thresh,
      'skipped_not_quarter_close', (cfg.category = 'quarter_sp' AND NOT v_is_quarter_close)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'week_end_date', p_week_end_date,
    'is_quarter_close', v_is_quarter_close,
    'all_star_hits_this_run', v_all_star_hits,
    'trailblazer_hits_this_run', v_trailblazer_hits,
    'leaderboard_updates_this_run', v_leaderboard_updates,
    'categories', v_cat_result,
    'ran_at', now()
  );
END;
$function$;

-- ─────────────────────────────────────────────────────────────────
-- 3) write_weekly_comp_v2 — LEFT UNTOUCHED.
--    Only remaining "podium" reference is a single audit-trail comment
--    inside the function body ("-- 2026-07-14: renamed podium -> leaderboard...").
--    Not user-visible (only appears via pg_get_functiondef). Explains why the
--    CTE names + JSON key evolved. Historical documentation; not "using" podium
--    as terminology. Rewriting the 200-line function body to drop one comment
--    line adds noise with zero behavioral benefit — deliberate no-op.
-- ─────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────
-- 4) Refresh frozen residual_pool_diag for the current in-progress week.
--    compute_pool_carveouts formula string change flows into
--    weekly_cpr_team_detail.residual_pool_diag on next write_weekly_comp_v2 run.
-- ─────────────────────────────────────────────────────────────────
SELECT public.write_weekly_comp_v2(
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  '2026-07-18'::date
);

-- ─────────────────────────────────────────────────────────────────
-- 5) Surgical JSONB text-replace on frozen 2026-07-11 goals_detail.formula.
--    Old formula string still says "$10 per Podium entry" — swap to "Leaderboard entry".
--    Only touches the formula text; leaves all values (hits, dollars) unchanged.
-- ─────────────────────────────────────────────────────────────────
UPDATE public.weekly_cpr_team_detail d
SET residual_pool_diag = jsonb_set(
      d.residual_pool_diag,
      '{goals_detail,formula}',
      to_jsonb('$10 win-the-week (team) + $10 1% gain + $10 per All-Star crossing + $10 per Leaderboard entry + $10 per Trailblazer crossing'::text)
    )
FROM public.weekly_cpr_reports r
WHERE r.id = d.weekly_cpr_report_id
  AND d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND r.week_ending_date = '2026-07-11'
  AND d.residual_pool_diag->'goals_detail'->>'formula' ILIKE '%Podium entry%';
