-- Peter directive 2026-07-12 pm3: add "4-week sales" leaderboard (rolling 4-week SP sum).
-- Same leaderboard/all-star/trailblazer mechanics as week_sp / week_quotes / quarter_sp.

-- ── 0. Widen CHECK constraints across the 4 tables that pin the category to a fixed list ──
ALTER TABLE public.leaderboard_floor_config DROP CONSTRAINT IF EXISTS leaderboard_floor_config_category_check;
ALTER TABLE public.leaderboard_floor_config
  ADD CONSTRAINT leaderboard_floor_config_category_check
  CHECK (category = ANY (ARRAY['quarter_sp','week_sp','week_quotes','four_week_sp']));

ALTER TABLE public.leaderboards DROP CONSTRAINT IF EXISTS leaderboards_category_check;
ALTER TABLE public.leaderboards
  ADD CONSTRAINT leaderboards_category_check
  CHECK (category = ANY (ARRAY['quarter_sp','week_sp','week_quotes','four_week_sp']));

ALTER TABLE public.all_star_counts DROP CONSTRAINT IF EXISTS all_star_counts_category_check;
ALTER TABLE public.all_star_counts
  ADD CONSTRAINT all_star_counts_category_check
  CHECK (category = ANY (ARRAY['quarter_sp','week_sp','week_quotes','four_week_sp']));

ALTER TABLE public.trailblazer_crossings DROP CONSTRAINT IF EXISTS trailblazer_crossings_category_check;
ALTER TABLE public.trailblazer_crossings
  ADD CONSTRAINT trailblazer_crossings_category_check
  CHECK (category = ANY (ARRAY['quarter_sp','week_sp','week_quotes','four_week_sp']));

-- ── 1. Floor config ─────────────────────────────────────────────
INSERT INTO public.leaderboard_floor_config (category, round_step, round_direction, description)
VALUES ('four_week_sp', 200, 'floor', 'Rolling 4-week sales points all-star floor = bronze rounded down to nearest 200')
ON CONFLICT (category) DO NOTHING;

-- ── 2. Helper: rolling 4-week SP per person at week W ──────────
-- Formula:
--   Case A — window fully within curr Q (weeks_elapsed_in_Q >= 4):
--     rolling_4wk = QTD(W) - QTD(W-4wks in same Q)
--   Case B — window straddles quarter boundary (weeks_elapsed < 4):
--     rolling_4wk = QTD(W) + (4 - weeks_elapsed) / 13 * prior_Q_total
--
-- QTD(W-4) missing → treated as 0.
-- Prior Q missing → contribution 0.
CREATE OR REPLACE FUNCTION public.compute_rolling_4wk_sp(
  p_agency_id uuid,
  p_week_end_date date,
  p_team_member_id uuid
) RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_q_start           date;
  v_weeks_elapsed     int;
  v_curr_qtd          numeric := 0;
  v_qtd_minus_4       numeric := 0;
  v_prior_q_total     numeric := 0;
  v_result            numeric;
BEGIN
  v_q_start := date_trunc('quarter', p_week_end_date::timestamp)::date;
  v_weeks_elapsed := ((p_week_end_date - v_q_start) / 7) + 1;

  SELECT COALESCE(d.sales_points, 0)
    INTO v_curr_qtd
  FROM public.weekly_cpr_team_detail d
  JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
  WHERE r.agency_id = p_agency_id
    AND d.team_member_id = p_team_member_id
    AND r.week_ending_date = p_week_end_date;

  v_curr_qtd := COALESCE(v_curr_qtd, 0);

  IF v_weeks_elapsed >= 4 THEN
    SELECT COALESCE(d.sales_points, 0)
      INTO v_qtd_minus_4
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND d.team_member_id = p_team_member_id
      AND r.week_ending_date = (p_week_end_date - INTERVAL '28 days')::date
      AND r.week_ending_date >= v_q_start;

    v_qtd_minus_4 := COALESCE(v_qtd_minus_4, 0);
    v_result := GREATEST(0, v_curr_qtd - v_qtd_minus_4);
    RETURN v_result;
  END IF;

  SELECT d.sales_points
    INTO v_prior_q_total
  FROM public.weekly_cpr_team_detail d
  JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
  WHERE r.agency_id = p_agency_id
    AND d.team_member_id = p_team_member_id
    AND d.sales_points IS NOT NULL
    AND date_trunc('quarter', r.week_ending_date::timestamp)::date < v_q_start
  ORDER BY r.week_ending_date DESC
  LIMIT 1;

  v_prior_q_total := COALESCE(v_prior_q_total, 0);

  v_result := v_curr_qtd + ((4 - v_weeks_elapsed)::numeric / 13.0) * v_prior_q_total;
  RETURN GREATEST(0, v_result);
END;
$$;

-- ── 3. Seed leaderboards (smooth-avg 4-week from historical quarter totals) ──
-- Provisional: quarter_total × 4/13. Walk-based tier-aware peaks would be higher.
INSERT INTO public.leaderboards (agency_id, category, tier, team_member_id, record_value, record_period_label, record_week_ending, set_at, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'four_week_sp', 1,
    'ea296434-7802-4370-9cb9-f689df722830', 2260.85, 'Q1 2026 (smooth avg)', '2026-03-28', now(),
    'Provisional seed: quarter_total × 4/13'),
  ('126794dd-25ff-47d2-a436-724499733365', 'four_week_sp', 2,
    'ea296434-7802-4370-9cb9-f689df722830', 1711.38, 'Q4 2025 (smooth avg)', '2025-12-27', now(),
    'Provisional seed: quarter_total × 4/13'),
  ('126794dd-25ff-47d2-a436-724499733365', 'four_week_sp', 3,
    '893c77db-1d39-4870-8433-434d9ba07b84', 1593.61, 'Q2 2026 (smooth avg)', '2026-06-27', now(),
    'Provisional seed: quarter_total × 4/13');

-- ── 4. Update audit_weekly_leaderboard_crossings — add four_week_sp branch ──
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
        AND t.role_category = 'Sales'
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
