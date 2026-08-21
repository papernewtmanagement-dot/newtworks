-- Align trailblazer_crossings column names with all_star_crossings for consistency.
-- Rationale: both tables serve the same purpose (record a person crossing a numeric threshold
-- for a leaderboard category in a given week), but originally shipped with different column
-- names. Every caller has to remember which shape it is. Consolidating on the all_star shape
-- (value_at_crossing / floor_at_crossing) since that's the canonical naming used by the audit
-- function's all_star branch.

ALTER TABLE public.trailblazer_crossings
  RENAME COLUMN crossing_value TO value_at_crossing;

ALTER TABLE public.trailblazer_crossings
  RENAME COLUMN threshold_at_crossing TO floor_at_crossing;

-- Update audit_weekly_leaderboard_crossings: single INSERT line changes.
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

-- Update compose_weekly_cpr_html: trailblazer subquery now uses value_at_crossing / floor_at_crossing.
CREATE OR REPLACE FUNCTION public.compose_weekly_cpr_html(p_agency_id uuid, p_week_ending_date date)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_report          public.weekly_cpr_reports;
  v_week_start      date;
  v_start_mon       text;
  v_end_mon         text;
  v_start_day       text;
  v_end_day         text;
  v_subject_range   text;
  v_cpr_url         text;
  v_opener_html     text;
  v_lookahead_html  text;
  v_wtw_html        text := '';
  v_mvp_html        text := '';
  v_mvp_name        text;
  v_mvp_sp          numeric;
  v_mvp_draws       int;
  v_draws_label     text;
  v_crossings_html  text := '';
  v_all_star_rows   text := '';
  v_trailblazer_rows text := '';
  v_payroll_html    text := '';
  v_html            text;
  v_team_quotes     int := 0;
  v_team_sp         numeric := 0;
  v_quote_goal      int := 0;
  v_sp_goal         numeric := 0;
  v_quote_short     int;
  v_sp_short        numeric;
  v_quotes_pass     boolean;
  v_sp_pass         boolean;
BEGIN
  SELECT * INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No weekly_cpr_reports row for agency=% week=%', p_agency_id, p_week_ending_date;
  END IF;

  v_week_start := p_week_ending_date - 6;
  v_cpr_url := 'https://newtworks.vercel.app/cpr/' || to_char(p_week_ending_date, 'YYYY-MM-DD');

  v_start_mon := upper(to_char(v_week_start,       'Mon'));
  v_end_mon   := upper(to_char(p_week_ending_date, 'Mon'));
  v_start_day := to_char(v_week_start,       'FMDD');
  v_end_day   := to_char(p_week_ending_date, 'FMDD');
  IF v_start_mon = v_end_mon THEN
    v_subject_range := v_start_mon || ' ' || v_start_day || '-' || v_end_day;
  ELSE
    v_subject_range := v_start_mon || ' ' || v_start_day || ' - ' || v_end_mon || ' ' || v_end_day;
  END IF;

  v_opener_html := COALESCE(
    NULLIF(replace(replace(replace(v_report.opener_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), ''),
    '<em style="color:#94a3b8">Opener not yet drafted.</em>'
  );
  v_lookahead_html := COALESCE(
    NULLIF(replace(replace(replace(v_report.looking_next_week_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), ''),
    '<em style="color:#94a3b8">Looking ahead not yet drafted.</em>'
  );

  SELECT
    COALESCE(SUM(r.net_quotes), 0)::int,
    COALESCE(SUM(d.sales_points), 0)::numeric
  INTO v_team_quotes, v_team_sp
  FROM public.weekly_cpr_team_detail d
  JOIN public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date) r
    ON r.team_member_id = d.team_member_id
  WHERE d.weekly_cpr_report_id = v_report.id;

  SELECT COALESCE(quotes_target_total, 0), COALESCE(sp_target, 0)
  INTO v_quote_goal, v_sp_goal
  FROM public.get_win_the_week_state(p_agency_id, p_week_ending_date);

  v_quotes_pass := v_team_quotes >= v_quote_goal;
  v_sp_pass     := v_team_sp     >= v_sp_goal;

  IF v_quotes_pass AND v_sp_pass THEN
    v_wtw_html := '<div style="padding:12px 16px;background:#dcfce7;border-radius:6px;margin:20px 0;color:#166534;font-weight:700;font-size:15px">🏆 WIN THE WEEK — ✓ Team hit both goals</div>';

    SELECT COALESCE(NULLIF(t.nickname,''), t.first_name), mh.sales_points_earned, mh.prize_draws
    INTO v_mvp_name, v_mvp_sp, v_mvp_draws
    FROM public.mvp_history mh
    JOIN public.team t ON t.id = mh.team_member_id
    WHERE mh.agency_id = p_agency_id AND mh.week_ending_date = p_week_ending_date
    LIMIT 1;

    IF v_mvp_name IS NOT NULL THEN
      v_draws_label := v_mvp_draws::text || ' prize draw' || CASE WHEN v_mvp_draws = 1 THEN '' ELSE 's' END;
      v_mvp_html :=
        '<div style="padding:14px 18px;background:linear-gradient(90deg,#dcfce7 0%,#bbf7d0 100%);border:2px solid #16a34a;border-radius:10px;margin:0 0 20px;display:flex;flex-direction:column;gap:4px">' ||
          '<div style="font-size:11px;font-weight:700;color:#166534;text-transform:uppercase;letter-spacing:0.5px">🏆 This Week''s MVP</div>' ||
          '<div style="font-size:20px;font-weight:800;color:#14532d">' || v_mvp_name || '</div>' ||
          '<div style="font-size:13px;color:#166534">' || round(v_mvp_sp)::text || ' SP earned · ' || v_draws_label || '</div>' ||
        '</div>';
    END IF;
  ELSE
    v_quote_short := GREATEST(0, v_quote_goal - v_team_quotes);
    v_sp_short    := GREATEST(0, v_sp_goal   - v_team_sp);
    v_wtw_html :=
      '<div style="padding:12px 16px;background:#fef2f2;border-radius:6px;margin:20px 0;color:#991b1b;font-weight:700;font-size:15px">🏆 WIN THE WEEK — Carryover' ||
      CASE
        WHEN v_quote_short > 0 AND v_sp_short > 0 THEN ' ' || v_quote_short::text || ' quotes / ' || round(v_sp_short)::text || ' pts'
        WHEN v_quote_short > 0                    THEN ' ' || v_quote_short::text || ' quotes'
        WHEN v_sp_short    > 0                    THEN ' ' || round(v_sp_short)::text || ' pts'
        ELSE ''
      END ||
      '</div>';
  END IF;

  -- All-Star & Trailblazer crossings share the same column shape now
  -- (value_at_crossing / floor_at_crossing). Two separate subqueries kept for
  -- record vs floor phrasing distinction.
  SELECT string_agg(row_html, '' ORDER BY sort_order) INTO v_all_star_rows
  FROM (
    SELECT
      CASE ac.category
        WHEN 'quarter_sp'   THEN 1
        WHEN 'four_week_sp' THEN 2
        WHEN 'week_sp'      THEN 3
        WHEN 'week_quotes'  THEN 4
        ELSE 9
      END AS sort_order,
      '<div style="padding:4px 0;font-size:13px;color:#334155">' ||
        '<span style="font-weight:700;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</span> — ' ||
        CASE ac.category
          WHEN 'week_quotes' THEN round(ac.value_at_crossing)::text || ' Weekly Quotes (floor ' || round(ac.floor_at_crossing)::text || ')'
          WHEN 'week_sp'      THEN '$' || to_char(ac.value_at_crossing, 'FM999,999,990') || ' Weekly Sales (floor $' || to_char(ac.floor_at_crossing, 'FM999,999,990') || ')'
          WHEN 'four_week_sp' THEN '$' || to_char(ac.value_at_crossing, 'FM999,999,990') || ' 4-Week Sales (floor $' || to_char(ac.floor_at_crossing, 'FM999,999,990') || ')'
          WHEN 'quarter_sp'   THEN '$' || to_char(ac.value_at_crossing, 'FM999,999,990') || ' Quarterly Sales (floor $' || to_char(ac.floor_at_crossing, 'FM999,999,990') || ')'
          ELSE ac.category || ' ' || round(ac.value_at_crossing)::text
        END ||
      '</div>' AS row_html
    FROM public.all_star_crossings ac
    JOIN public.team t ON t.id = ac.team_member_id
    WHERE ac.agency_id = p_agency_id AND ac.week_ending = p_week_ending_date
  ) rows;

  SELECT string_agg(row_html, '' ORDER BY sort_order) INTO v_trailblazer_rows
  FROM (
    SELECT
      CASE tc.category
        WHEN 'quarter_sp'   THEN 1
        WHEN 'four_week_sp' THEN 2
        WHEN 'week_sp'      THEN 3
        WHEN 'week_quotes'  THEN 4
        ELSE 9
      END AS sort_order,
      '<div style="padding:4px 0;font-size:13px;color:#334155">' ||
        '<span style="font-weight:700;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</span> — ' ||
        CASE tc.category
          WHEN 'week_quotes' THEN round(tc.value_at_crossing)::text || ' Weekly Quotes (record ' || round(tc.floor_at_crossing)::text || ')'
          WHEN 'week_sp'      THEN '$' || to_char(tc.value_at_crossing, 'FM999,999,990') || ' Weekly Sales (record $' || to_char(tc.floor_at_crossing, 'FM999,999,990') || ')'
          WHEN 'four_week_sp' THEN '$' || to_char(tc.value_at_crossing, 'FM999,999,990') || ' 4-Week Sales (record $' || to_char(tc.floor_at_crossing, 'FM999,999,990') || ')'
          WHEN 'quarter_sp'   THEN '$' || to_char(tc.value_at_crossing, 'FM999,999,990') || ' Quarterly Sales (record $' || to_char(tc.floor_at_crossing, 'FM999,999,990') || ')'
          ELSE tc.category || ' ' || round(tc.value_at_crossing)::text
        END ||
      '</div>' AS row_html
    FROM public.trailblazer_crossings tc
    JOIN public.team t ON t.id = tc.team_member_id
    WHERE tc.agency_id = p_agency_id AND tc.week_ending = p_week_ending_date
  ) rows;

  IF v_all_star_rows IS NOT NULL OR v_trailblazer_rows IS NOT NULL THEN
    v_crossings_html := '<div style="padding:14px 18px;background:#fefce8;border:1px solid #fde68a;border-radius:8px;margin:0 0 20px">';
    IF v_all_star_rows IS NOT NULL THEN
      v_crossings_html := v_crossings_html ||
        '<div style="font-size:11px;font-weight:700;color:#854d0e;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:4px">⭐ All-Star Crossings</div>' ||
        v_all_star_rows;
    END IF;
    IF v_trailblazer_rows IS NOT NULL THEN
      v_crossings_html := v_crossings_html ||
        '<div style="font-size:11px;font-weight:700;color:#7c2d12;text-transform:uppercase;letter-spacing:0.5px;margin:8px 0 4px">🔥 Trailblazer Crossings</div>' ||
        v_trailblazer_rows;
    END IF;
    v_crossings_html := v_crossings_html || '</div>';
  END IF;

  SELECT string_agg(row_html, '' ORDER BY start_date)
  INTO v_payroll_html
  FROM (
    SELECT
      t.start_date,
      '<tr>' ||
        '<td style="padding:6px 10px;color:#1e293b;font-weight:600;font-size:14px">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>' ||
        '<td style="padding:6px 10px;text-align:right;color:#1e293b;font-weight:700;font-size:14px">$' ||
          to_char(
            (COALESCE(d.base_salary,0) + COALESCE(d.commission,0) + COALESCE(d.bonus,0)
             + COALESCE(d.marketing_pool_earned_weekly,0) + COALESCE(d.manager_bonus,0)
             + COALESCE(d.health_bonus,0)
             + COALESCE(t.annual_benefits_value,0)/52.0),
            'FM999,999,990.00'
          ) ||
        '</td>' ||
      '</tr>' AS row_html
    FROM public.weekly_cpr_team_detail d
    JOIN public.team t ON t.id = d.team_member_id
    WHERE d.weekly_cpr_report_id = v_report.id
      AND t.category = 'agency'
      AND t.is_active = true
      AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz)
      AND NOT COALESCE(t.is_admin_backoffice, false)
      AND COALESCE(t.role_level,'') != 'Owner'
  ) rows;

  v_payroll_html := COALESCE(v_payroll_html, '');

  v_html :=
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen,Ubuntu,sans-serif;max-width:600px;margin:0 auto;padding:20px;color:#1e293b">' ||
      '<h2 style="margin:0 0 20px;font-size:20px;color:#1e293b">📊 CPR RECAP — WEEK OF ' || v_subject_range || '</h2>' ||
      v_mvp_html ||
      v_crossings_html ||
      '<div style="color:#b91c1c;font-size:15px;line-height:1.6;margin-bottom:6px">' || v_opener_html || '</div>' ||
      v_wtw_html ||
      '<h3 style="margin:24px 0 8px;font-size:16px;color:#1e293b">💰 WEEKLY PAY</h3>' ||
      '<table style="width:100%;border-collapse:collapse;background:#f8fafc;border-radius:6px;overflow:hidden">' ||
        '<tbody>' || v_payroll_html || '</tbody>' ||
      '</table>' ||
      '<div style="margin:24px 0;text-align:center">' ||
        '<a href="' || v_cpr_url || '" style="display:inline-block;padding:10px 18px;background:#1e40af;color:#ffffff;text-decoration:none;border-radius:6px;font-weight:600">📋 View full CPR report →</a>' ||
      '</div>' ||
      '<h3 style="margin:24px 0 8px;font-size:16px;color:#1e293b">🎯 LOOKING AT NEXT WEEK</h3>' ||
      '<div style="color:#1e40af;font-size:15px;line-height:1.6;margin-bottom:24px">' || v_lookahead_html || '</div>' ||
      '<p style="color:#64748b;font-size:14px;margin:24px 0 0">— Peter</p>' ||
    '</div>';

  RETURN v_html;
END;
$function$;
