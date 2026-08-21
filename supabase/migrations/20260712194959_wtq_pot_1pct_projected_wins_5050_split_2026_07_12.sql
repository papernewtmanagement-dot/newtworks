-- Peter directive 2026-07-12 pm4:
-- (1) STOP filtering audit_weekly_leaderboard_crossings by role_category='Sales'. Cassie and Stephanie belong on sales leaderboards like anyone else.
-- (2) WtQ + Prize Cart pot: multiplier 3% -> 1%, pace uses PROJECTED wins (assume all future weeks won), split 30/70 -> 50/50, sub-label 'Top Sales'.
-- (3) Formula label reads: 1% OT (SMVC + Scorecard) × projected_wins/13 weeks won

-- ── 1. Remove role_category='Sales' from audit function ─────────────────────
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
  v_leaderboard_updates     int := 0;
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
        INSERT INTO public.trailblazer_crossings
          (agency_id, category, team_member_id, crossing_value, threshold_at_crossing, period_label, week_ending)
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

-- ── 2. WtQ pot: 1% × OT (SMVC + Scorecard) × projected-wins/13, 50/50 split ──
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

  -- Peter directive 2026-07-12 pm4: rate 1%, pace = projected (curr wins + future weeks assumed won) / 13
  v_rate                CONSTANT numeric := 0.01;
  v_pace                numeric := 0;
  v_pool_pace_dollars   numeric := 0;

  v_annual_mvp          numeric := 0;
  v_annual_wtq          numeric := 0;
  v_wtq_halted          boolean := false;
  v_wtq_halt_reason     text := NULL;

  v_mvp_share_pct       CONSTANT numeric := 0.50;
  v_rest_share_pct      CONSTANT numeric := 0.50;
  v_team_count          int := 0;
  v_rest_count          int := 0;
  v_mvp_dollars         numeric := 0;
  v_rest_pool_dollars   numeric := 0;
  v_rest_per_person     numeric := 0;

  v_total_carveouts     numeric;
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

  -- Projected wins: actual wins so far + assume all remaining weeks are won.
  v_weeks_remaining := GREATEST(0, 13 - v_week_of_cycle);
  v_projected_wins  := v_curr_qtr_wins + v_weeks_remaining;

  -- New pace: projected / 13 (capped at 100%).
  v_pace := LEAST(1.0, v_projected_wins::numeric / 13.0);
  v_pool_pace_dollars := v_rate * v_annual_ot_basis * v_pace;

  IF v_projected_wins < 9 THEN
    v_annual_wtq      := 0;
    v_wtq_halted      := true;
    v_wtq_halt_reason := format(
      'projected_wins (%s) < 9 floor. actual %s wins so far, %s weeks remaining, assuming all remaining win.',
      v_projected_wins, v_curr_qtr_wins, v_weeks_remaining
    );
  ELSE
    v_annual_wtq := v_pool_pace_dollars;
  END IF;

  v_annual_mvp := v_pool_pace_dollars;

  SELECT COUNT(*) INTO v_team_count
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date);
  v_rest_count        := GREATEST(0, v_team_count - 1);
  v_mvp_dollars       := v_annual_wtq * v_mvp_share_pct;
  v_rest_pool_dollars := v_annual_wtq * v_rest_share_pct;
  v_rest_per_person   := CASE
    WHEN v_rest_count > 0 THEN v_rest_pool_dollars / v_rest_count::numeric
    ELSE 0
  END;

  v_total_carveouts := v_annual_manager_bonus
                    + v_annual_life_ins
                    + v_annual_apparel
                    + v_annual_hdb
                    + v_annual_cc
                    + v_annual_mvp
                    + v_annual_wtq;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'week_end_date', p_week_end_date,
    'design_note', 'Carve-and-forget: unearned carveouts stay with agency (do NOT reconcile back to pool).',
    'inputs', jsonb_build_object(
      'annual_ot_smvc',              ROUND(v_annual_ot_smvc, 2),
      'annual_ot_scorecard',         ROUND(v_annual_ot_scorecard, 2),
      'annual_ot_basis',             ROUND(v_annual_ot_basis, 2),
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
      'pace_formula',                'LEAST(1.0, (curr_wins + weeks_remaining) / 13.0) — assumes all remaining weeks win'
    ),
    'manager_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_manager_bonus, 2),
      'weekly_dollars', ROUND(v_annual_manager_bonus / 52.0, 2),
      'formula',        'sum(role_level_pct × on-time Scorecard annual): UM=0.1%, SectM=0.2%, OM=0.3%',
      'detail',         v_manager_detail
    ),
    'life_insurance_stipend', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_life_ins, 2),
      'weekly_dollars', ROUND(v_annual_life_ins / 52.0, 2),
      'formula',        'sum(monthly_cap_by_year_of_employment × 12) across active non-owner roster',
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
      'formula',        '$25/week × 52 weeks per active non-owner team member (structural max)',
      'detail',         v_hdb_detail
    ),
    'champions_circle', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_cc, 2),
      'weekly_dollars', ROUND(v_annual_cc / 52.0, 2),
      'pct_of_basis',   v_cc_pct,
      'formula',        '3% × on-time (SMVC + Scorecard) annual basis, flat accrual'
    ),
    'mvp_prize_cart', jsonb_build_object(
      'annual_dollars',    ROUND(v_annual_mvp, 2),
      'weekly_dollars',    ROUND(v_annual_mvp / 52.0, 2),
      'formula',           '1% × on-time (SMVC + Scorecard) × projected_wins/13 (assumes all remaining weeks won)',
      'rate_pct',          v_rate,
      'pace',              ROUND(v_pace, 4),
      'projected_wins',    v_projected_wins,
      'note',              'Same formula as WtQ Trip. No floor. If team is on-time to win every week, pool is maxed.'
    ),
    'wtq_trip', jsonb_build_object(
      'annual_dollars',    ROUND(v_annual_wtq, 2),
      'weekly_dollars',    ROUND(v_annual_wtq / 52.0, 2),
      'formula',           '1% × on-time (SMVC + Scorecard) × projected_wins/13 (assumes all remaining weeks won)',
      'rate_pct',          v_rate,
      'pace',              ROUND(v_pace, 4),
      'projected_wins',    v_projected_wins,
      'floor_wins',        9,
      'halted',            v_wtq_halted,
      'halt_reason',       v_wtq_halt_reason,
      'note',              'Same formula as MVP Prize Cart. Halts to $0 if projected total wins < 9-wins floor.',
      'mvp_share_pct',           v_mvp_share_pct,
      'rest_share_pct',          v_rest_share_pct,
      'rest_split_rule',         'evenly per non-MVP teammate (MVP does NOT receive share of the rest pool)',
      'team_count',              v_team_count,
      'rest_of_team_count',      v_rest_count,
      'mvp_dollars',             ROUND(v_mvp_dollars, 2),
      'rest_pool_dollars',       ROUND(v_rest_pool_dollars, 2),
      'rest_per_person_dollars', ROUND(v_rest_per_person, 2)
    ),
    'total_annual_carveouts', ROUND(v_total_carveouts, 2),
    'total_weekly_carveouts', ROUND(v_total_carveouts / 52.0, 2),
    'computed_at', now()
  );
END;
$function$;

-- ── 3. Quarter-close dispatcher: rate 3% -> 1%; pace stays actual/13 (quarter is closed, no projection) ──
CREATE OR REPLACE FUNCTION public.quarter_close_prize_cart_and_leaderboards(p_agency_id uuid, p_quarter_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_next_q_end          date;
  v_carried             int := 0;
  v_carried_value_total numeric := 0;
  v_smvc_annual         numeric := 0;
  v_scorecard_annual    numeric := 0;
  v_ot_basis_annual     numeric := 0;
  v_closing_qtr_wins    int := 0;
  v_pace                numeric := 0;
  v_rate                CONSTANT numeric := 0.01;
  v_next_budget         numeric := 0;
  v_available_budget    numeric := 0;
  v_pool_result         jsonb;
  v_audit_result        jsonb;
  v_result              jsonb;
  v_pending_id          uuid;
  v_peter_chat_id       bigint;
  v_telegram_text       text;
BEGIN
  v_next_q_end := p_quarter_ending_date + INTERVAL '13 weeks';

  WITH carried AS (
    INSERT INTO public.prize_cart (
      agency_id, quarter_ending_date, display_order,
      prize_description, prize_url, prize_value
    )
    SELECT agency_id, v_next_q_end, display_order,
           prize_description, prize_url, prize_value
    FROM public.prize_cart
    WHERE agency_id = p_agency_id
      AND quarter_ending_date = p_quarter_ending_date
      AND winner_team_member_id IS NULL
    RETURNING prize_value
  )
  SELECT COUNT(*), COALESCE(SUM(prize_value), 0)
  INTO v_carried, v_carried_value_total
  FROM carried;

  v_pool_result       := public.compute_pool_basis_and_envelope(p_agency_id, p_quarter_ending_date);
  v_smvc_annual       := COALESCE((v_pool_result->'basis'->>'on_time_smvc_dollars')::numeric, 0);
  v_scorecard_annual  := COALESCE((v_pool_result->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_ot_basis_annual   := v_smvc_annual + v_scorecard_annual;

  SELECT COUNT(*) INTO v_closing_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date > (p_quarter_ending_date - INTERVAL '13 weeks')
    AND week_ending_date <= p_quarter_ending_date
    AND won_the_week = true;

  -- At quarter close: pace = actual wins / 13 (no projection needed — quarter is done)
  v_pace        := LEAST(1.0, v_closing_qtr_wins::numeric / 13.0);
  v_next_budget := ROUND(v_rate * v_ot_basis_annual * v_pace, 2);

  INSERT INTO public.quarter_prize_budgets (agency_id, quarter_ending_date, budget_dollars, formula_note)
  VALUES (p_agency_id, v_next_q_end, v_next_budget,
          format('1%% × on-time (SMVC $%s + Scorecard $%s) × %s/13 weeks won = $%s',
                 v_smvc_annual::text, v_scorecard_annual::text, v_closing_qtr_wins::text, v_next_budget::text))
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET budget_dollars = EXCLUDED.budget_dollars,
        formula_note   = EXCLUDED.formula_note;

  v_available_budget := ROUND(v_next_budget - v_carried_value_total, 2);

  INSERT INTO public.pending_prize_research (
    agency_id, quarter_ending_date, available_budget_dollars,
    carried_prize_count, carried_prize_value_total, status, notes
  )
  VALUES (
    p_agency_id, v_next_q_end, v_available_budget,
    v_carried, v_carried_value_total, 'pending',
    format('Quarter closed %s. %s prizes carried ($%s total). Budget $%s (1%% × OT basis × %s/13 wins). Available for new prizes: $%s.',
           p_quarter_ending_date::text, v_carried, v_carried_value_total::text,
           v_next_budget::text, v_closing_qtr_wins::text, v_available_budget::text)
  )
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET available_budget_dollars = EXCLUDED.available_budget_dollars,
        carried_prize_count      = EXCLUDED.carried_prize_count,
        carried_prize_value_total= EXCLUDED.carried_prize_value_total,
        status                   = 'pending',
        updated_at               = now()
  RETURNING id INTO v_pending_id;

  BEGIN
    v_audit_result := public.audit_weekly_leaderboard_crossings(p_agency_id, p_quarter_ending_date);
  EXCEPTION WHEN OTHERS THEN
    v_audit_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE);
  END;

  INSERT INTO public.alerts (agency_id, module_reference, severity, title, description, is_resolved)
  VALUES (
    p_agency_id, 'prize_cart_refresh', 'medium',
    format('Prize cart refresh — $%s available (Q ending %s)',
           v_available_budget::text, to_char(v_next_q_end, 'YYYY-MM-DD')),
    format('Quarter closed. %s prizes carried ($%s). Budget $%s (%s/13 wins). Available for new prizes: $%s. '
           'Run Claude session with op-rule "Newtworks quarter-end prize cart research" to research + verify links + propose new items.',
           v_carried, v_carried_value_total::text, v_next_budget::text, v_closing_qtr_wins::text, v_available_budget::text),
    false
  );

  SELECT telegram_user_id INTO v_peter_chat_id
  FROM public.team_telegram_map
  WHERE agency_id = p_agency_id
    AND telegram_first_name = 'Peter'
    AND telegram_last_name = 'Story'
  LIMIT 1;

  IF v_peter_chat_id IS NOT NULL THEN
    v_telegram_text :=
      '🏆 Prize cart refresh ready' || chr(10) || chr(10) ||
      'Quarter closed: ' || p_quarter_ending_date::text || ' -> next quarter ends ' || v_next_q_end::text || chr(10) ||
      '• ' || v_carried::text || ' prizes carried ($' || v_carried_value_total::text || ' total value)' || chr(10) ||
      '• Closing quarter wins: ' || v_closing_qtr_wins::text || '/13 (pace ' || ROUND(v_pace, 4)::text || ')' || chr(10) ||
      '• Next quarter budget: $' || v_next_budget::text || chr(10) ||
      '• Available for new prizes: $' || v_available_budget::text || chr(10) || chr(10) ||
      'Start a Claude session and say "run prize cart research" — Claude will use the ' ||
      '"Newtworks quarter-end prize cart research" operational rule to verify all links ' ||
      'and propose new prizes within budget.';

    BEGIN
      PERFORM public.paper_newt_send_message(v_peter_chat_id, v_telegram_text, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  v_result := jsonb_build_object(
    'quarter_ending_date',        p_quarter_ending_date,
    'next_quarter_ending_date',   v_next_q_end,
    'prizes_carried',             v_carried,
    'carried_value_total',        v_carried_value_total,
    'closing_qtr_wins',           v_closing_qtr_wins,
    'pace',                       ROUND(v_pace, 4),
    'rate_pct',                   v_rate,
    'ot_basis_annual',            v_ot_basis_annual,
    'next_quarter_budget_dollars',v_next_budget,
    'available_budget_dollars',   v_available_budget,
    'pending_prize_research_id',  v_pending_id,
    'leaderboard_audit_result',   v_audit_result,
    'ran_at',                     now()
  );

  RETURN v_result;
END;
$function$;
