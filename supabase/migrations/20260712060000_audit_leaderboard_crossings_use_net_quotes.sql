-- Fix: week_quotes leaderboard should compare NET QUOTES (quotes_discussed - paid), not quotes_modified.
-- quotes_modified is a small adjustment column, not the productivity metric.
-- Symptom (2026-07-12): John Kostov had 30 discussed / 29 net for week 2026-07-11 but stayed off the podium
-- because audit function was reading d.quotes_modified (=0 for John) instead of net_quotes.

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
  v_podium_updates     int := 0;
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
          SELECT COUNT(*) INTO v_podium_updates FROM (
            SELECT v_podium_updates + (SELECT COUNT(*) FROM reinserted) AS x
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
    'podium_updates_this_run', v_podium_updates,
    'categories', v_cat_result,
    'ran_at', now()
  );
END;
$function$;
