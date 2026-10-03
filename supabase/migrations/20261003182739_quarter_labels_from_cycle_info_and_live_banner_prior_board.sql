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
  v_quarter_start    := (SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci);

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
            -- This week's earnings: quarter-to-date now, less quarter-to-date a week ago.
            GREATEST(0,
              COALESCE((SELECT f.sales_points
                          FROM public.sales_points_qtd_for(p_agency_id, p_week_end_date, t.id) f), 0)
              - CASE WHEN (p_week_end_date - 7) >= v_quarter_start
                     THEN COALESCE((SELECT f2.sales_points
                                      FROM public.sales_points_qtd_for(p_agency_id, (p_week_end_date - 7), t.id) f2), 0)
                     ELSE 0 END
            )
          WHEN 'four_week_sp' THEN
            public.compute_rolling_4wk_sp(p_agency_id, p_week_end_date, t.id)
          WHEN 'quarter_sp' THEN
            -- The quarter figure is the quarter-to-date number at the close week,
            -- not the sum of every week's running total.
            COALESCE((SELECT f.sales_points
                        FROM public.sales_points_qtd_for(p_agency_id, v_cycle_end, t.id) f), 0)::numeric
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
        -- Quarter label comes from current_cycle_info (13-week quarters). The calendar quarter of the
        -- closing Saturday is the NEXT quarter when that Saturday falls in a new month (Oct 3 2026 = Q3, not Q4).
        period_lbl := (SELECT cci.quarter_label FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci);
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
        -- Append-only ledger. One entry per person per category per period, so re-running the
        -- same week updates the entry in place instead of adding a second one. The board is
        -- rebuilt from this ledger at the end of the run, which means a record that gets
        -- deleted lets the record it displaced come straight back (Peter 2026-09-11).
        INSERT INTO public.leaderboard_entries
          (agency_id, category, team_member_id, record_value, record_period_label, record_week_ending)
        VALUES (p_agency_id, cfg.category, r.team_member_id, r.the_value, period_lbl,
                CASE WHEN cfg.category = 'quarter_sp' THEN NULL ELSE p_week_end_date END)
        ON CONFLICT (agency_id, category, team_member_id, record_period_label)
        DO UPDATE SET record_value       = EXCLUDED.record_value,
                      record_week_ending = EXCLUDED.record_week_ending,
                      set_at             = now();
        v_leaderboard_updates := v_leaderboard_updates + 1;
      END IF;
    END LOOP;

    v_cat_result := v_cat_result || jsonb_build_object(
      'category', cfg.category,
      'floor', floor_val,
      'trailblazer_threshold', trailblazer_thresh,
      'skipped_not_quarter_close', (cfg.category = 'quarter_sp' AND NOT v_is_quarter_close)
    );
  END LOOP;

  PERFORM public.rebuild_leaderboards_from_entries(p_agency_id);

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

CREATE OR REPLACE FUNCTION public.reset_open_week_snapshots(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sent_at    timestamptz;
  v_found      boolean;
  v_locked     boolean;
  v_as_deleted int := 0;
  v_tb_deleted int := 0;
  v_lb_deleted int := 0;
  v_mvp_reset  boolean := false;
  v_mvp_note   text := 'no mvp row for this week';
  v_draws      int := 0;
  v_cycle_end  date;
  v_qtr_label  text;
BEGIN
  SELECT true, sent_to_team_at INTO v_found, v_sent_at
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF NOT COALESCE(v_found, false) THEN
    RETURN jsonb_build_object('reset', false, 'reason', 'no weekly_cpr_reports row for week');
  END IF;


  v_locked := public.week_locked_at(p_agency_id, p_week_end_date) IS NOT NULL;

  IF v_locked THEN
    RETURN jsonb_build_object('reset', false, 'reason', 'week is frozen by payroll');
  END IF;

  UPDATE public.all_star_counts c
  SET count = GREATEST(0, c.count - x.n), updated_at = now()
  FROM (
    SELECT team_member_id, category, COUNT(*)::int AS n
    FROM public.all_star_crossings
    WHERE agency_id = p_agency_id AND week_ending = p_week_end_date
    GROUP BY team_member_id, category
  ) x
  WHERE c.agency_id = p_agency_id
    AND c.team_member_id = x.team_member_id
    AND c.category = x.category;

  WITH del AS (
    DELETE FROM public.all_star_crossings
    WHERE agency_id = p_agency_id AND week_ending = p_week_end_date
    RETURNING 1
  ) SELECT COUNT(*)::int INTO v_as_deleted FROM del;

  WITH del AS (
    DELETE FROM public.trailblazer_crossings
    WHERE agency_id = p_agency_id AND week_ending = p_week_end_date
    RETURNING 1
  ) SELECT COUNT(*)::int INTO v_tb_deleted FROM del;

  SELECT cci.cycle_end INTO v_cycle_end
  FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci;
  v_qtr_label := (SELECT cci.quarter_label FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci);

  WITH del AS (
    DELETE FROM public.leaderboard_entries
    WHERE agency_id = p_agency_id
      AND (record_week_ending = p_week_end_date
           OR (category = 'quarter_sp'
               AND v_cycle_end = p_week_end_date
               AND record_period_label = v_qtr_label))
    RETURNING 1
  ) SELECT COUNT(*)::int INTO v_lb_deleted FROM del;

  IF v_lb_deleted > 0 THEN
    PERFORM public.rebuild_leaderboards_from_entries(p_agency_id);
  END IF;

  SELECT COUNT(*)::int INTO v_draws
  FROM public.mvp_prize_draws
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF EXISTS (SELECT 1 FROM public.mvp_history
             WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date) THEN
    IF v_draws > 0 THEN
      v_mvp_note := 'kept - ' || v_draws || ' prize draw(s) already taken for this week';
    ELSE
      DELETE FROM public.mvp_history
      WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;
      v_mvp_reset := true;
      v_mvp_note  := 'cleared for rebuild';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'reset', true,
    'week_end_date', p_week_end_date,
    'all_star_crossings_cleared', v_as_deleted,
    'trailblazer_crossings_cleared', v_tb_deleted,
    'leaderboard_entries_cleared', v_lb_deleted,
    'mvp_row_cleared', v_mvp_reset,
    'mvp_note', v_mvp_note,
    'ran_at', now()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.write_weekly_comp_v2(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_rows_updated int := 0;
  v_wt_rows int := 0;
  v_report_id      uuid;
  v_floor_diag     jsonb;
  v_won_the_week   boolean;
  v_mktg_result    jsonb;
  v_audit_result   jsonb;
  v_quarter_start  date;
  v_cycle_end      date;
  v_is_qtr_close   boolean;
  v_qtr_close_period_label text;
  v_mvp_id         uuid;
  v_mvp_new_sp     numeric;
  v_mvp_draws      int;
  v_mvp_row_exists boolean;
  v_mvp_result     jsonb;
  v_reset_result   jsonb;
  v_goals_rows_updated int := 0;
  v_goals_detail   jsonb := '[]'::jsonb;
  v_prefill_result jsonb;
  v_sent_at        timestamptz;
  v_wtw_adj        jsonb;
  v_wtw_adj_rows   int := 0;
  v_comm_proj_result jsonb;
  v_pool_cumulative  numeric;
BEGIN
  v_prefill_result := public.prefill_weekly_cpr_form(p_agency_id, p_week_end_date);

  SELECT id, won_the_week INTO v_report_id, v_won_the_week
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date
  LIMIT 1;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object('agency_id', p_agency_id, 'week_end_date', p_week_end_date,
      'rows_updated', 0, 'note', 'no weekly_cpr_reports row exists for this week', 'written_at', now());
  END IF;

  v_quarter_start := (SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci);

  SELECT ci.cycle_end INTO v_cycle_end FROM public.current_cycle_info(p_agency_id, p_week_end_date) ci;
  v_is_qtr_close := (v_cycle_end = p_week_end_date);
  v_qtr_close_period_label := (SELECT cci.quarter_label FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci);

  -- WtW $10/quote-under requirements adjustment (locked 2026-08-05, forward-only from week ending 2026-08-08).
  -- Condition of earning, never a wage deduction. Computed here so it's available to fold into the
  -- residual-pool split below AND stamped onto both report/detail rows for page + email display.
  v_wtw_adj := public.compute_wtw_requirements_adjustment(p_agency_id, p_week_end_date);

  v_floor_diag := public.compute_retention_floor_factor(p_agency_id, p_week_end_date);

  UPDATE public.weekly_cpr_reports
  SET wtw_requirements_adjustment_quotes = COALESCE((v_wtw_adj->'team'->>'quotes_under')::int, 0),
      wtw_requirements_adjustment = COALESCE((v_wtw_adj->'team'->>'dollars')::numeric, 0),
      agency_lapse_auto_at_write = ROUND(NULLIF(v_floor_diag->>'our_auto','')::numeric, 6),
      agency_lapse_fire_at_write = ROUND(NULLIF(v_floor_diag->>'our_fire','')::numeric, 6),
      retention_floor_factor = NULLIF(v_floor_diag->>'factor','')::numeric,
      updated_at = now()
  WHERE id = v_report_id;

  WITH src AS (SELECT * FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date)),
       carveouts AS (SELECT public.compute_pool_carveouts(p_agency_id, p_week_end_date) AS data),
       hdb_by_person AS (
         SELECT (elem->>'team_member_id')::uuid AS team_id, (elem->>'weekly_max_dollars')::numeric AS weekly_max
         FROM carveouts, LATERAL jsonb_array_elements(carveouts.data->'health_development_bonus'->'detail') elem),
       health_hits AS (SELECT team_id, hits FROM public.compute_team_health_weekly_hits(p_agency_id, p_week_end_date)),
       /* canonical weekly sales-points delta (2026-09-20): same function the pool math uses */
       comm_calc AS (
         SELECT swd.team_member_id, swd.week_delta AS weekly_commission_sp_delta
         FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd),
       wtw_team_dollars AS (SELECT COALESCE((v_wtw_adj->'team'->>'dollars')::numeric, 0) AS d),
       wtw_person AS (
         SELECT (elem->>'team_member_id')::uuid AS team_member_id,
                COALESCE((elem->>'quotes_under')::int, 0) AS quotes_under,
                COALESCE((elem->>'dollars')::numeric, 0) AS dollars
         FROM jsonb_array_elements(COALESCE(v_wtw_adj->'people', '[]'::jsonb)) elem),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET base_salary = s.weekly_base_salary,
        commission  = COALESCE(cc.weekly_commission_sp_delta, s.weekly_commission_projected),
        bonus       = s.weekly_bonus * v_scale.scale,
        sales_pool_share     = s.weekly_sales_pool_share * v_scale.scale,
        retention_pool_share = s.weekly_retention_pool_share * v_scale.scale,
        retention_guarantee_topup = COALESCE(s.weekly_retention_topup, 0) * v_scale.scale,
        retention_points_pay = COALESCE(s.weekly_retention_guarantee, 0) * v_scale.scale,
        wtw_requirements_adjustment_quotes = COALESCE(wp.quotes_under, 0),
        wtw_requirements_adjustment = COALESCE(wp.dollars, 0),
        manager_bonus = CASE WHEN COALESCE((s.diagnostics->>'departed_this_week')::boolean, false) THEN 0
                             ELSE COALESCE((SELECT (mgr->>'weekly_bonus_dollars')::numeric FROM jsonb_array_elements(COALESCE(s.diagnostics->'carveouts_detail'->'manager_bonus'->'detail', '[]'::jsonb)) mgr WHERE mgr->>'team_member_id' = wctd.team_member_id::text LIMIT 1), 0) END,
        health_bonus = CASE WHEN COALESCE((SELECT hits FROM health_hits hh WHERE hh.team_id = wctd.team_member_id), 0) >= 5 THEN COALESCE((SELECT weekly_max FROM hdb_by_person hp WHERE hp.team_id = wctd.team_member_id), 0) ELSE 0 END,
        residual_pool_diag = s.diagnostics || jsonb_build_object(
          'annual_base_salary', s.annual_base_salary, 'annual_commission_projected', s.annual_commission_projected,
          'annual_bonus', s.annual_bonus, 'annual_total_comp', s.annual_total_comp,
          'ytd_sales_points', s.ytd_sales_points, 'sales_points_share_pct', s.sales_points_share_pct,
          'weighted_hours_at_40', s.weighted_hours_at_40, 'retention_hours_share_pct', s.retention_hours_share_pct,
          'retention_net_points', s.retention_net_points, 'retention_points_share_pct', s.retention_points_share_pct, 'weekly_retention_guarantee', s.weekly_retention_guarantee, 'weekly_retention_topup', s.weekly_retention_topup,
          'person_share_pct', s.person_share_pct,
          'wtw_requirements_adjustment', jsonb_build_object(
            'team_dollars_prorated_to_person', ROUND(v_scale.team_alloc, 2),
            'individual_dollars', COALESCE(wp.dollars, 0),
            'individual_quotes_under', COALESCE(wp.quotes_under, 0),
            'scale_applied', ROUND(v_scale.scale, 6),
            'formula', 'bonus/sales_pool_share/retention_pool_share scaled by max(0, weekly_bonus - (team_charge*person_share_pct/100 + individual_charge)) / weekly_bonus')),
        updated_at = now()
    FROM src s
    LEFT JOIN comm_calc cc ON cc.team_member_id = s.team_member_id
    LEFT JOIN wtw_person wp ON wp.team_member_id = s.team_member_id
    CROSS JOIN wtw_team_dollars wtd
    CROSS JOIN LATERAL (
      SELECT
        (wtd.d * s.person_share_pct / 100.0) AS team_alloc,
        CASE WHEN s.weekly_bonus > 0
          THEN GREATEST(0, s.weekly_bonus - ((wtd.d * s.person_share_pct / 100.0) + COALESCE(wp.dollars, 0))) / s.weekly_bonus
          ELSE 0
        END AS scale
    ) v_scale
    WHERE wctd.weekly_cpr_report_id = v_report_id AND wctd.team_member_id = s.team_member_id
    RETURNING wctd.id)
  SELECT COUNT(*) INTO v_rows_updated FROM upd;

  SELECT COUNT(*) INTO v_wtw_adj_rows FROM jsonb_array_elements(COALESCE(v_wtw_adj->'people', '[]'::jsonb));

  WITH wt AS (SELECT * FROM public.compute_warning_trigger(p_agency_id, p_week_end_date)),
  wt_upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET fully_loaded_annual = w.fully_loaded_annual, attributed_revenue_annual = w.attributed_revenue_annual,
        own_new_business_annualized = w.own_new_business_annualized, own_renewal_stack_credited = w.own_renewal_stack_credited,
        retention_pool_share_annual = w.retention_pool_share_annual, retention_quality_multiplier = w.retention_quality_multiplier,
        coverage_bar = w.coverage_bar, coverage_pct = w.coverage_pct, coverage_status = w.coverage_status,
        profitability_bar = w.profitability_bar, profitability_pct = w.profitability_pct, profitability_status = w.profitability_status,
        lapse_rate_used = w.lapse_rate_used, lapse_status = w.lapse_status, renewal_stack_annual = w.renewal_stack_annual,
        warning_bar = w.warning_bar, warning_actual_annual = w.warning_actual_annual, warning_pct = w.warning_pct,
        warning_status = w.warning_status, warning_diag = w.diag, updated_at = now()
    FROM wt w WHERE wctd.weekly_cpr_report_id = v_report_id AND wctd.team_member_id = w.team_member_id
    RETURNING wctd.id)
  SELECT COUNT(*) INTO v_wt_rows FROM wt_upd;

  BEGIN v_mktg_result := public.write_weekly_marketing_bonus(p_agency_id, p_week_end_date);
  EXCEPTION WHEN OTHERS THEN v_mktg_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE); END;
  -- Peter ruling 2026-09-11: All-Star, Trailblazer and MVP compute live until the week is
  -- frozen. Clear this week snapshots first so the audit and the MVP detection below rebuild
  -- them from the sales points as they stand right now, rather than keeping what was true on
  -- Saturday night. reset_open_week_snapshots is a no-op once the week is frozen, so a week
  -- the team has already seen never moves.
  BEGIN v_reset_result := public.reset_open_week_snapshots(p_agency_id, p_week_end_date);
  EXCEPTION WHEN OTHERS THEN v_reset_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE); END;

  BEGIN v_audit_result := public.audit_weekly_leaderboard_crossings(p_agency_id, p_week_end_date);
  EXCEPTION WHEN OTHERS THEN v_audit_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE); END;

  BEGIN
    WITH this_new_sp AS (
      SELECT d.team_member_id, COALESCE(swd.week_delta, 0)::numeric AS this_wk_new_sp
      FROM public.weekly_cpr_team_detail d
      LEFT JOIN public.sales_points_week_delta(p_agency_id, p_week_end_date) swd
        ON swd.team_member_id = d.team_member_id
      WHERE d.weekly_cpr_report_id = v_report_id),
    last_completed_q AS (
      SELECT DISTINCT ON (d.team_member_id) d.team_member_id,
        COALESCE(d.sales_points_frozen, d.sales_points) AS q_total,
        r.week_ending_date AS q_end_sat,
        (SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, r.week_ending_date) cci) AS q_start
      FROM public.weekly_cpr_team_detail d JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
      WHERE r.agency_id = p_agency_id AND COALESCE(d.sales_points_frozen, d.sales_points) IS NOT NULL
        AND (SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, r.week_ending_date) cci) < v_quarter_start
      ORDER BY d.team_member_id, r.week_ending_date DESC),
    last_week_delta AS (
      SELECT swd.team_member_id, swd.week_delta AS last_wk_new_sp
      FROM public.sales_points_week_delta(p_agency_id, p_week_end_date - 7) swd),
    prior_avg AS (
      SELECT lcq.team_member_id,
             (((lcq.q_total / 13.0) * 12 + COALESCE(lwd.last_wk_new_sp, 0)) / 13.0)::numeric AS avg_new_sp,
             lcq.q_end_sat, lcq.q_total,
             COALESCE(lwd.last_wk_new_sp, 0) AS last_wk_new_sp
      FROM last_completed_q lcq
      LEFT JOIN last_week_delta lwd ON lwd.team_member_id = lcq.team_member_id
    ),
    as_counts AS (SELECT team_member_id, COUNT(*) AS n FROM public.all_star_crossings WHERE agency_id = p_agency_id AND week_ending = p_week_end_date GROUP BY team_member_id),
    tb_counts AS (SELECT team_member_id, COUNT(*) AS n FROM public.trailblazer_crossings WHERE agency_id = p_agency_id AND week_ending = p_week_end_date GROUP BY team_member_id),
    leaderboard_counts AS (SELECT team_member_id, COUNT(*) AS n FROM public.leaderboards
      WHERE agency_id = p_agency_id AND category IN ('quarter_sp','week_sp','week_quotes','four_week_sp') AND (record_week_ending = p_week_end_date OR (v_is_qtr_close AND category = 'quarter_sp' AND record_period_label = v_qtr_close_period_label))
      GROUP BY team_member_id),
    per_person AS (
      SELECT t.team_member_id, t.this_wk_new_sp,
        COALESCE(a.avg_new_sp, 0)::numeric AS avg_prior_13wk, COALESCE(a.q_total, 0)::numeric AS ref_quarter_total, COALESCE(a.last_wk_new_sp, 0)::numeric AS last_wk_new_sp,
        a.q_end_sat AS ref_quarter_end, COALESCE(a.avg_new_sp, 0)::numeric * 1.01 AS target_1pct,
        (COALESCE(a.avg_new_sp, 0) > 0 AND t.this_wk_new_sp >= COALESCE(a.avg_new_sp, 0) * 1.01) AS gain_hit,
        COALESCE(asc_.n, 0)::int AS as_hits, COALESCE(lc.n, 0)::int AS leaderboard_hits,
        COALESCE(tb.n, 0)::int AS tb_hits, COALESCE(v_won_the_week, false) AS won_the_week
      FROM this_new_sp t LEFT JOIN prior_avg a ON a.team_member_id = t.team_member_id
      LEFT JOIN as_counts asc_ ON asc_.team_member_id = t.team_member_id
      LEFT JOIN leaderboard_counts lc ON lc.team_member_id = t.team_member_id
      LEFT JOIN tb_counts tb ON tb.team_member_id = t.team_member_id),
    with_dollars AS (SELECT p.*,
      /* terminated anywhere in the week: no goals bonus (Peter 2026-09-06) */
      (CASE WHEN EXISTS (SELECT 1 FROM public.team tx WHERE tx.id = p.team_member_id AND tx.end_date IS NOT NULL AND tx.end_date <= p_week_end_date) OR public.team_is_owner(p.team_member_id) /* owner row is only for his wrap-up: no goals bonus */ THEN 0 ELSE 10 END
       * (p.as_hits + p.tb_hits + p.leaderboard_hits + CASE WHEN p.gain_hit THEN 1 ELSE 0 END + CASE WHEN p.won_the_week THEN 1 ELSE 0 END))::numeric AS dollars FROM per_person p),
    goals_upd AS (
      UPDATE public.weekly_cpr_team_detail wctd
      SET goals_bonus = w.dollars,
          residual_pool_diag = COALESCE(wctd.residual_pool_diag, '{}'::jsonb) || jsonb_build_object(
            'goals_detail', jsonb_build_object(
              'won_the_week', w.won_the_week, 'gain_hit', w.gain_hit,
              'as_hits', w.as_hits, 'leaderboard_hits', w.leaderboard_hits, 'tb_hits', w.tb_hits,
              'this_wk_new_sp', ROUND(w.this_wk_new_sp, 2), 'avg_prior_13wk', ROUND(w.avg_prior_13wk, 2),
              'ref_quarter_total', ROUND(w.ref_quarter_total, 2), 'ref_quarter_end', w.ref_quarter_end, 'last_wk_new_sp', ROUND(COALESCE(w.last_wk_new_sp,0), 2),
              'target_1pct', ROUND(w.target_1pct, 2), 'dollars', w.dollars,
              'formula', '$10 win-the-week (team) + $10 1% gain + $10 per All-Star crossing + $10 per Leaderboard entry + $10 per Trailblazer crossing')),
          updated_at = now()
      FROM with_dollars w WHERE wctd.weekly_cpr_report_id = v_report_id AND wctd.team_member_id = w.team_member_id
      RETURNING w.team_member_id, wctd.id AS row_id, w.dollars, w.won_the_week, w.gain_hit, w.as_hits, w.leaderboard_hits, w.tb_hits, w.this_wk_new_sp, w.target_1pct)
    SELECT COUNT(*), COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', team_member_id, 'row_id', row_id, 'dollars', dollars, 'won_the_week', won_the_week, 'gain_hit', gain_hit,
      'as_hits', as_hits, 'leaderboard_hits', leaderboard_hits, 'tb_hits', tb_hits,
      'this_wk_new_sp', this_wk_new_sp, 'target_1pct', target_1pct)), '[]'::jsonb)
    INTO v_goals_rows_updated, v_goals_detail FROM goals_upd;
  EXCEPTION WHEN OTHERS THEN v_goals_detail := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE); END;

  v_mvp_result := jsonb_build_object('detected', false, 'reason', 'not evaluated');
  IF COALESCE(v_won_the_week, false) THEN
    SELECT EXISTS (SELECT 1 FROM public.mvp_history WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date) INTO v_mvp_row_exists;
    IF v_mvp_row_exists THEN v_mvp_result := jsonb_build_object('detected', false, 'reason', 'mvp_history row already exists for this week');
    ELSE
      WITH deltas AS (
        SELECT d.team_member_id, COALESCE(swd.week_delta, 0)::numeric AS new_sp
        FROM public.weekly_cpr_team_detail d
        LEFT JOIN public.sales_points_week_delta(p_agency_id, p_week_end_date) swd
          ON swd.team_member_id = d.team_member_id
        WHERE d.weekly_cpr_report_id = v_report_id
          /* terminated anywhere in the week: not eligible for MVP (Peter 2026-09-06) */
          AND NOT EXISTS (SELECT 1 FROM public.team tx WHERE tx.id = d.team_member_id AND tx.end_date IS NOT NULL AND tx.end_date <= p_week_end_date)
          AND NOT public.team_is_owner(d.team_member_id))
      SELECT team_member_id, new_sp INTO v_mvp_id, v_mvp_new_sp FROM deltas WHERE public.compute_mvp_prize_draws(p_agency_id, new_sp) > 0 /* title starts at the first draw (Peter 2026-09-26) */ ORDER BY new_sp DESC LIMIT 1;
      IF v_mvp_id IS NOT NULL THEN
        v_mvp_draws := public.compute_mvp_prize_draws(p_agency_id, v_mvp_new_sp);
        INSERT INTO public.mvp_history (agency_id, week_ending_date, team_member_id, sales_points_earned, prize_draws) VALUES (p_agency_id, p_week_end_date, v_mvp_id, v_mvp_new_sp, v_mvp_draws);
        v_mvp_result := jsonb_build_object('detected', true, 'team_member_id', v_mvp_id, 'new_sp', v_mvp_new_sp, 'prize_draws', v_mvp_draws);
      ELSE v_mvp_result := jsonb_build_object('detected', false, 'reason', 'no teammate reached the first prize-cart draw this week'); END IF;
    END IF;
  ELSE v_mvp_result := jsonb_build_object('detected', false, 'reason', 'team did not win the week'); END IF;

  SELECT MAX((r.diagnostics->'qtd_subtractions'->>'qtd_bonus_paid_prior')::numeric)
         + MAX((r.diagnostics->'qtd_pools'->>'qtd_bonus_pool')::numeric)
    INTO v_pool_cumulative
  FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date) r;

  IF public.week_locked_at(p_agency_id, p_week_end_date) IS NOT NULL THEN
    v_comm_proj_result := jsonb_build_object('skipped', true, 'reason', 'week frozen by payroll');
  ELSE
    v_comm_proj_result := public.write_commission_projection(p_agency_id, p_week_end_date, v_pool_cumulative);
  END IF;

  RETURN jsonb_build_object('agency_id', p_agency_id, 'week_end_date', p_week_end_date, 'weekly_cpr_report_id', v_report_id,
    'rows_updated', v_rows_updated, 'warning_trigger_rows_updated', v_wt_rows,
    'marketing_bonus_result', v_mktg_result, 'leaderboard_audit_result', v_audit_result,
    'goals_bonus_rows_updated', v_goals_rows_updated, 'goals_bonus_detail', v_goals_detail,
    'wtw_requirements_adjustment', v_wtw_adj, 'wtw_requirements_adjustment_people_count', v_wtw_adj_rows,
    'open_week_reset_result', v_reset_result,
    'mvp_detection_result', v_mvp_result,
    'commission_projection_result', v_comm_proj_result,
    'prefill_result', v_prefill_result,
    'written_at', now());
END;
$function$;

CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(team_member_id uuid, full_name text, role text, role_category text, role_level text, annual_base_salary numeric, weekly_base_salary numeric, annual_commission_projected numeric, weekly_commission_projected numeric, ytd_sales_points numeric, sales_points_share_pct numeric, weighted_hours_at_40 numeric, retention_hours_share_pct numeric, retention_net_points numeric, retention_points_share_pct numeric, weekly_retention_guarantee numeric, weekly_retention_topup numeric, person_share_pct numeric, annual_bonus numeric, weekly_bonus numeric, weekly_sales_pool_share numeric, weekly_retention_pool_share numeric, annual_total_comp numeric, weekly_total_comp numeric, diagnostics jsonb)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_cycle_start date; v_cycle_end date; v_week_of_cycle int; v_weeks_in_cycle int := 13;
  v_year int := (SELECT cci.quarter_year FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci); v_quarter int := (SELECT cci.quarter_number FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci);
  v_pool_result jsonb; v_carveouts_result jsonb;
  v_annual_basis numeric; v_current_pool_pct numeric; v_qtd_envelope numeric; v_cycle_envelope numeric; v_weekly_envelope numeric;
  v_burden_mult CONSTANT numeric := 0.08; v_wc_annual CONSTANT numeric := 500.00;
  v_qtd_wc numeric; v_weekly_apparel numeric; v_weekly_life_ins numeric; v_weekly_cc_reserve numeric;
  v_weekly_prize_cart numeric; v_weekly_wtq_trip numeric;
  v_weekly_hdb numeric; v_qtd_hdb_max numeric;
  v_qtd_apparel numeric; v_qtd_life_ins numeric; v_qtd_cc_reserve numeric;
  v_weekly_wtw_bonus numeric; v_weekly_gain_bonus numeric; v_weekly_leaderboard_bonus numeric; v_weekly_all_star_bonus numeric; v_weekly_trailblazer_bonus numeric; v_weekly_goals_total numeric;
  v_retention_floor_factor numeric;
  v_retention_floor_diag jsonb;
  v_rp_go_live date;  -- first week-ending Saturday paid on Retention Points (Peter 2026-08-26: no trial period, live when built; Activity Log shipped 2026-08-31)
  v_points_mode boolean;
  v_accrual jsonb; v_accrual_applies boolean; v_comm_charge numeric;
  v_reserve_rate CONSTANT numeric := 0.30; v_reserve_decay numeric;
  v_recapture_from CONSTANT date := '2026-08-30';  -- departure recapture is forward-only (Peter 2026-09-06)
BEGIN
  SELECT cycle_start, cycle_end, week_of_cycle INTO v_cycle_start, v_cycle_end, v_week_of_cycle FROM public.current_cycle_info(p_agency_id, p_week_end_date);
  IF v_cycle_start IS NULL THEN RETURN; END IF;
  v_accrual := public.compute_commission_accrual(p_agency_id, p_week_end_date);
  v_accrual_applies := COALESCE((v_accrual->>'applies_to_pool')::boolean, false);
  v_comm_charge := COALESCE(NULLIF(v_accrual->>'accrual_charge_qtd','')::numeric, 0);
  v_reserve_decay := GREATEST(0, 1.0 - (v_week_of_cycle::numeric / v_weeks_in_cycle::numeric));
  v_pool_result := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_carveouts_result := public.compute_pool_carveouts(p_agency_id, p_week_end_date);
  v_annual_basis := COALESCE(NULLIF(v_pool_result->'basis'->>'total_basis_annual','')::numeric, 0);
  v_current_pool_pct := COALESCE(NULLIF(v_pool_result->'schedule'->>'pool_pct','')::numeric, 0);
  v_weekly_envelope := (v_annual_basis * v_current_pool_pct / 100.0) / 52.0;
  SELECT COALESCE(SUM(COALESCE(l.weekly_envelope_locked, (v_annual_basis * s.pool_pct / 100.0) / 52.0)), 0) INTO v_qtd_envelope FROM public.team_comp_pool_schedule s LEFT JOIN public.weekly_pool_lock l ON l.agency_id = s.agency_id AND l.week_end_date = s.week_end_date WHERE s.agency_id = p_agency_id AND s.week_end_date >= v_cycle_start AND s.week_end_date <= p_week_end_date;
  SELECT COALESCE(SUM((v_annual_basis * pool_pct / 100.0) / 52.0), 0) INTO v_cycle_envelope FROM public.team_comp_pool_schedule WHERE agency_id = p_agency_id AND week_end_date >= v_cycle_start AND week_end_date <= v_cycle_end;
  v_weekly_apparel := COALESCE(NULLIF(v_carveouts_result->'apparel'->>'weekly_dollars','')::numeric, 0);
  v_weekly_life_ins := COALESCE(NULLIF(v_carveouts_result->'life_insurance_stipend'->>'weekly_dollars','')::numeric, 0);
  v_weekly_cc_reserve := COALESCE(NULLIF(v_carveouts_result->'champions_circle'->>'weekly_dollars','')::numeric, 0);
  v_weekly_prize_cart := COALESCE(NULLIF(v_carveouts_result->'mvp_prize_cart'->>'weekly_dollars','')::numeric, 0);
  v_weekly_wtq_trip := COALESCE(NULLIF(v_carveouts_result->'wtq_trip'->>'weekly_dollars','')::numeric, 0);
  v_weekly_hdb := COALESCE(NULLIF(v_carveouts_result->'health_development_bonus'->>'weekly_dollars','')::numeric, 0);
  SELECT COALESCE(SUM(CASE WHEN s.week_end_date = p_week_end_date THEN v_weekly_hdb
                           ELSE COALESCE((SELECT NULLIF(dd.residual_pool_diag->'carveouts_detail'->'health_development_bonus'->>'weekly_dollars', '')::numeric
                                            FROM public.weekly_cpr_team_detail dd
                                            JOIN public.weekly_cpr_reports rr2 ON rr2.id = dd.weekly_cpr_report_id
                                           WHERE rr2.agency_id = p_agency_id AND rr2.week_ending_date = s.week_end_date
                                             AND dd.residual_pool_diag ? 'carveouts_detail'
                                           ORDER BY dd.updated_at DESC LIMIT 1), v_weekly_hdb) END), 0)
    INTO v_qtd_hdb_max
    FROM public.team_comp_pool_schedule s
   WHERE s.agency_id = p_agency_id AND s.week_end_date >= v_cycle_start AND s.week_end_date <= p_week_end_date;
  v_weekly_wtw_bonus := COALESCE(NULLIF(v_carveouts_result->'wtw_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_gain_bonus := COALESCE(NULLIF(v_carveouts_result->'gain_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_leaderboard_bonus := COALESCE(NULLIF(v_carveouts_result->'leaderboard_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_all_star_bonus := COALESCE(NULLIF(v_carveouts_result->'all_star_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_trailblazer_bonus := COALESCE(NULLIF(v_carveouts_result->'trailblazer_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_goals_total := v_weekly_wtw_bonus + v_weekly_gain_bonus + v_weekly_leaderboard_bonus + v_weekly_all_star_bonus + v_weekly_trailblazer_bonus;
  v_qtd_wc := (v_wc_annual / 52.0) * v_week_of_cycle;
  v_retention_floor_diag := public.compute_retention_floor_factor(p_agency_id, p_week_end_date);
  v_retention_floor_factor := NULLIF(v_retention_floor_diag->>'factor','')::numeric;
  SELECT NULLIF(btrim(s.setting_value), '')::date INTO v_rp_go_live
    FROM public.settings s
    WHERE s.agency_id = p_agency_id AND s.setting_key = 'retention_points_go_live_week_end';
  v_points_mode := (v_rp_go_live IS NOT NULL AND p_week_end_date >= v_rp_go_live);
  v_qtd_apparel := v_weekly_apparel * v_week_of_cycle; v_qtd_life_ins := v_weekly_life_ins * v_week_of_cycle; v_qtd_cc_reserve := v_weekly_cc_reserve * v_week_of_cycle;
  RETURN QUERY
  WITH roster AS (
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
        AND COALESCE(t.start_date, p_week_end_date) <= p_week_end_date) AS in_week,
      /* terminated anywhere in the week (end_date <= that Saturday, Peter 2026-09-02 bar):
         paid base for days worked + commission only. No pool share, goals, manager bonus, MVP. */
      (COALESCE(t.end_date, dsnap.end_date, (t.archived_at AT TIME ZONE 'America/Chicago')::date) IS NOT NULL
        AND COALESCE(t.end_date, dsnap.end_date, (t.archived_at AT TIME ZONE 'America/Chicago')::date) <= p_week_end_date) AS left_in_week,
      (((t.archived_at IS NULL OR t.archived_at > (p_week_end_date - 6)::timestamptz)
        AND COALESCE(t.start_date, p_week_end_date) <= p_week_end_date)
       AND NOT (COALESCE(t.end_date, dsnap.end_date, (t.archived_at AT TIME ZONE 'America/Chicago')::date) IS NOT NULL
        AND COALESCE(t.end_date, dsnap.end_date, (t.archived_at AT TIME ZONE 'America/Chicago')::date) <= p_week_end_date)) AS shares_eligible
    FROM public.team t
    LEFT JOIN public.weekly_cpr_reports rr ON rr.agency_id = p_agency_id AND rr.week_ending_date = p_week_end_date
    LEFT JOIN public.weekly_cpr_team_detail dsnap ON dsnap.weekly_cpr_report_id = rr.id AND dsnap.team_member_id = t.id
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND COALESCE(t.is_admin_backoffice, false) = false
      AND t.is_test_user IS NOT TRUE
      AND COALESCE(t.start_date, p_week_end_date) <= p_week_end_date
      AND (t.archived_at IS NULL OR t.archived_at > (v_cycle_start - 364)::timestamptz)
  ),
  cycle_weeks AS (SELECT week_end_date FROM public.team_comp_pool_schedule WHERE agency_id = p_agency_id AND week_end_date >= v_cycle_start AND week_end_date <= p_week_end_date),
  per_week_pay AS (SELECT r.id AS tm_id, cw.week_end_date, COALESCE(dh.pay_type, r.pay_type) AS wk_pay_type, COALESCE(dh.pay_rate, r.pay_rate) AS wk_pay_rate FROM roster r CROSS JOIN cycle_weeks cw LEFT JOIN public.weekly_cpr_reports rh ON rh.agency_id = p_agency_id AND rh.week_ending_date = cw.week_end_date LEFT JOIN public.weekly_cpr_team_detail dh ON dh.weekly_cpr_report_id = rh.id AND dh.team_member_id = r.id),
  base_by_week AS (SELECT r.id AS tm_id, cw.week_end_date, COALESCE((SELECT COALESCE((pd.raw_earnings->'items'->'SALARY'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'REGULAR'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'HOURLY'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'PTO'->>'period')::numeric, 0) FROM public.payroll_detail pd JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id WHERE pd.agency_id = p_agency_id AND pd.team_member_id = r.id AND pr.pay_period_end = cw.week_end_date AND pr.pay_date <= p_week_end_date LIMIT 1), CASE WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN (SELECT CASE WHEN COUNT(*) = 0 THEN NULL ELSE ROUND((COALESCE(SUM(h.hours), 0) + COALESCE(SUM(h.paid_time_off_hours), 0)) * pwp.wk_pay_rate, 2) END FROM public.get_weekly_cpr_hours(p_agency_id, cw.week_end_date) h WHERE h.team_member_id = r.id) ELSE NULL END, CASE WHEN pwp.wk_pay_type = 'SALARY' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, cw.week_end_date) WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * 40 * public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, cw.week_end_date) ELSE 0 END) AS week_base_paid, public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) AS week_fraction, CASE WHEN r.end_date IS NOT NULL AND r.end_date <= cw.week_end_date THEN 0 ELSE public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) END AS benefit_week_fraction, LEAST(1.00, GREATEST(0, FLOOR((cw.week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS week_tenure_mult FROM roster r CROSS JOIN cycle_weeks cw JOIN per_week_pay pwp ON pwp.tm_id = r.id AND pwp.week_end_date = cw.week_end_date),
  base_qtd AS (SELECT tm_id, SUM(week_base_paid) AS qtd_base_paid, SUM(week_base_paid * week_tenure_mult) AS qtd_base_in_pool, SUM(week_base_paid * (1 - week_tenure_mult)) AS qtd_growth_budget, SUM(week_fraction) AS qtd_weeks_on_team, SUM(benefit_week_fraction) AS qtd_weeks_on_team_benefits FROM base_by_week GROUP BY tm_id),
  comm_by_week AS (
    SELECT r.id AS tm_id, cw.week_end_date,
      COALESCE(
        (SELECT SUM((kv.value->>'period')::numeric)
         FROM public.payroll_detail pd
         JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id
         CROSS JOIN LATERAL jsonb_each(COALESCE(pd.raw_earnings->'items', '{}'::jsonb)) kv
         WHERE pd.agency_id = p_agency_id
           AND pd.team_member_id = r.id
           AND pr.pay_period_end = cw.week_end_date
           AND pr.pay_date <= p_week_end_date
           AND kv.key ILIKE '%Comm%'),
        CASE WHEN cw.week_end_date = p_week_end_date THEN
          GREATEST(0,
            COALESCE((SELECT swd.qtd FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1), 0)
            -
            COALESCE((SELECT swd.prior_qtd FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1), 0)
          )
        END,
        (SELECT wctd.commission
         FROM public.weekly_cpr_team_detail wctd
         JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id
         WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date = cw.week_end_date
         LIMIT 1),
        0
      ) AS week_commission_paid
    FROM roster r CROSS JOIN cycle_weeks cw
  ),
  commission_qtd AS (SELECT tm_id, SUM(week_commission_paid) AS qtd_commission_paid FROM comm_by_week GROUP BY tm_id),
  bonus_paid_by_week AS (
    SELECT r.id AS tm_id, cw.week_end_date,
      COALESCE(
        (SELECT SUM((kv.value->>'period')::numeric)
         FROM public.payroll_detail pd
         JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id
         CROSS JOIN LATERAL jsonb_each(COALESCE(pd.raw_earnings->'items', '{}'::jsonb)) kv
         WHERE pd.agency_id = p_agency_id
           AND pd.team_member_id = r.id
           AND pr.pay_period_end = cw.week_end_date
           AND pr.pay_date <= p_week_end_date
           AND kv.key ILIKE '%Team%'),
        (SELECT wctd.bonus
         FROM public.weekly_cpr_team_detail wctd
         JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id
         WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date = cw.week_end_date
         LIMIT 1),
        0
      ) - COALESCE((SELECT wctd2.retention_guarantee_topup FROM public.weekly_cpr_team_detail wctd2 JOIN public.weekly_cpr_reports wr2 ON wr2.id = wctd2.weekly_cpr_report_id WHERE wr2.agency_id = p_agency_id AND wctd2.team_member_id = r.id AND wr2.week_ending_date = cw.week_end_date LIMIT 1), 0) AS week_bonus_paid
    FROM roster r CROSS JOIN cycle_weeks cw
    WHERE cw.week_end_date < p_week_end_date
  ),
  bonus_paid_prior_qtd AS (SELECT tm_id, SUM(week_bonus_paid) AS qtd_bonus_paid_prior FROM bonus_paid_by_week GROUP BY tm_id),
  mgr_bonus_by_week AS (
    SELECT r.id AS tm_id, cw.week_end_date,
      COALESCE(
        (SELECT SUM((kv.value->>'period')::numeric)
         FROM public.payroll_detail pd
         JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id
         CROSS JOIN LATERAL jsonb_each(COALESCE(pd.raw_earnings->'items', '{}'::jsonb)) kv
         WHERE pd.agency_id = p_agency_id
           AND pd.team_member_id = r.id
           AND pr.pay_period_end = cw.week_end_date
           AND pr.pay_date <= p_week_end_date
           AND kv.key ILIKE '%Manage%'),
        /* current week: live from this week's carve (0 if they left this week) — never the stored
           row, which this write is about to overwrite (one-cycle lag, same class as commission) */
        CASE WHEN cw.week_end_date = p_week_end_date THEN
          (CASE WHEN r.left_in_week THEN 0
                ELSE COALESCE((SELECT (mgr->>'weekly_bonus_dollars')::numeric
                               FROM jsonb_array_elements(COALESCE(v_carveouts_result->'manager_bonus'->'detail', '[]'::jsonb)) mgr
                               WHERE mgr->>'team_member_id' = r.id::text LIMIT 1), 0) END)
        END,
        (SELECT wctd.manager_bonus
         FROM public.weekly_cpr_team_detail wctd
         JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id
         WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date = cw.week_end_date
         LIMIT 1),
        0
      ) AS week_mgr_paid
    FROM roster r CROSS JOIN cycle_weeks cw
  ),
  mgr_bonus_qtd AS (SELECT tm_id, SUM(week_mgr_paid) AS qtd_mgr_paid FROM mgr_bonus_by_week GROUP BY tm_id),
  actual_base_this_week AS (SELECT r.id AS tm_id, COALESCE((SELECT COALESCE((pd.raw_earnings->'items'->'SALARY'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'REGULAR'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'HOURLY'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'PTO'->>'period')::numeric, 0) FROM public.payroll_detail pd JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id WHERE pd.agency_id = p_agency_id AND pd.team_member_id = r.id AND pr.pay_period_end = p_week_end_date AND pr.pay_date <= p_week_end_date LIMIT 1), CASE WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN (SELECT CASE WHEN COUNT(*) = 0 THEN NULL ELSE ROUND((COALESCE(SUM(h.hours), 0) + COALESCE(SUM(h.paid_time_off_hours), 0)) * r.pay_rate, 2) END FROM public.get_weekly_cpr_hours(p_agency_id, p_week_end_date) h WHERE h.team_member_id = r.id) ELSE NULL END, CASE WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, p_week_end_date) WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, p_week_end_date) ELSE 0 END) AS actual_base_paid FROM roster r),
  actuals_through_current AS (
    SELECT r.id AS tm_id,
      COALESCE(SUM(wctd.health_bonus), 0) AS qtd_hdb,
      (SELECT swd.qtd FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1) AS current_week_qtd_sp,
      GREATEST(0,
        COALESCE((SELECT swd.qtd FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1), 0)
        -
        COALESCE((SELECT swd.prior_qtd FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1), 0)
      ) AS current_week_comm
    FROM roster r
    LEFT JOIN public.weekly_cpr_reports wr ON wr.agency_id = p_agency_id AND wr.week_ending_date >= v_cycle_start AND wr.week_ending_date <= p_week_end_date
    LEFT JOIN public.weekly_cpr_team_detail wctd ON wctd.weekly_cpr_report_id = wr.id AND wctd.team_member_id = r.id
    GROUP BY r.id
  ),
  prior_paid AS (SELECT r.id AS tm_id, COALESCE(SUM(wctd.bonus), 0) AS prior_qtd_bonus_paid, COALESCE(SUM(wctd.sales_pool_share), 0) AS prior_qtd_sales_paid, COALESCE(SUM(wctd.retention_pool_share), 0) AS prior_qtd_retention_paid FROM roster r LEFT JOIN public.weekly_cpr_reports wr ON wr.agency_id = p_agency_id AND wr.week_ending_date >= v_cycle_start AND wr.week_ending_date < p_week_end_date LEFT JOIN public.weekly_cpr_team_detail wctd ON wctd.weekly_cpr_report_id = wr.id AND wctd.team_member_id = r.id GROUP BY r.id),
  carve_by_week AS (
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
    FROM carve_by_week),
  weeks_series AS (SELECT (p_week_end_date - (n * 7))::date AS week_ending, n AS lookback_idx FROM generate_series(0, 12) n),
  last_completed_q_per_person AS (SELECT DISTINCT ON (d.team_member_id) d.team_member_id, COALESCE(d.sales_points_frozen, d.sales_points) AS q_total, r.week_ending_date AS q_end_sat FROM public.weekly_cpr_team_detail d JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id WHERE r.agency_id = p_agency_id AND COALESCE(d.sales_points_frozen, d.sales_points) IS NOT NULL AND (SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, r.week_ending_date) cci) < (SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci) ORDER BY d.team_member_id, r.week_ending_date DESC),
  weekly_earned AS (SELECT r.id AS tm_id, ws.week_ending, ws.lookback_idx, CASE WHEN r.start_date IS NOT NULL AND ws.week_ending < r.start_date THEN 0 WHEN ws.week_ending = p_week_end_date THEN COALESCE((SELECT swd.week_delta FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1), 0) WHEN ws.week_ending >= v_cycle_start THEN COALESCE((SELECT wctd.commission FROM public.weekly_cpr_reports wr JOIN public.weekly_cpr_team_detail wctd ON wctd.weekly_cpr_report_id = wr.id WHERE wr.agency_id = p_agency_id AND wr.week_ending_date = ws.week_ending AND wctd.team_member_id = r.id LIMIT 1), 0) ELSE COALESCE((SELECT q_total / 13.0 FROM last_completed_q_per_person lcq WHERE lcq.team_member_id = r.id), 0) END AS earned_sp FROM roster r CROSS JOIN weeks_series ws),
  sp_rolling AS (SELECT tm_id, SUM(earned_sp) / 13.0 AS avg_13wk, SUM(CASE WHEN lookback_idx < 4 THEN earned_sp ELSE 0 END) / 4.0 AS avg_4wk FROM weekly_earned GROUP BY tm_id),
  wh_calc AS (SELECT r.id AS tm_id, 40.0 AS baseline_hours, CASE WHEN r.r_role_category = 'Retention' THEN 1.00 WHEN r.r_role_category = 'Sales' THEN 0.25 ELSE 0 END AS retention_weight_role, CASE WHEN r.work_location = 'in_office' THEN 1.00 WHEN r.work_location = 'remote' THEN 0.50 ELSE 1.00 END AS retention_weight_location, LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS retention_weight_tenure, LEAST(1.00, 0.50 + CASE WHEN r.license_pc THEN 0.35 ELSE 0 END + CASE WHEN r.license_lh THEN 0.10 ELSE 0 END + CASE WHEN r.license_ips THEN 0.05 ELSE 0 END) AS retention_weight_license FROM roster r),
  wh_final AS (SELECT tm_id, baseline_hours * retention_weight_role * retention_weight_location * retention_weight_tenure * retention_weight_license AS weighted_hours, retention_weight_role, retention_weight_location, retention_weight_tenure, retention_weight_license FROM wh_calc),
  retention_pts AS (SELECT x.team_member_id AS tm_id, COALESCE(x.net_points, 0) AS net_points, COALESCE(x.gross_points, 0) AS gross_points, COALESCE(x.missed_pct, 0) AS missed_pct, COALESCE(x.reduction_pct, 0) AS reduction_pct FROM public.compute_weekly_retention_points(p_agency_id, p_week_end_date) x),
  combined AS (SELECT r.id AS tm_id, r.in_week, r.left_in_week, r.shares_eligible, r.first_name, r.last_name, r.r_role, r.r_role_category, r.r_role_level, r.pay_type, r.pay_rate, CASE WHEN r.shares_eligible THEN r.weekly_health_benefit_agency_paid ELSE 0 END AS weekly_health_benefit_agency_paid, COALESCE(r.weekly_health_benefit_agency_paid, 0) * COALESCE(b.qtd_weeks_on_team_benefits, 0) AS c_health_qtd, COALESCE(b.qtd_base_paid, 0) AS c_qtd_base_paid, COALESCE(b.qtd_base_in_pool, 0) AS c_qtd_base_in_pool, COALESCE(b.qtd_growth_budget, 0) AS c_qtd_growth_budget, COALESCE(abt.actual_base_paid, 0) AS c_actual_base_this_week, COALESCE(mq.qtd_mgr_paid, 0) AS c_qtd_mgr, COALESCE(a.qtd_hdb, 0) AS c_qtd_hdb, COALESCE(cq.qtd_commission_paid, 0) AS c_qtd_comm, COALESCE(bpp.qtd_bonus_paid_prior, 0) AS c_qtd_bonus_paid_prior, CASE WHEN r.in_week THEN COALESCE(a.current_week_qtd_sp, 0) ELSE 0 END AS c_curr_qtd_sp, COALESCE(a.current_week_comm, 0) AS c_curr_comm, COALESCE(pp.prior_qtd_bonus_paid, 0) AS c_prior_qtd_bonus, COALESCE(pp.prior_qtd_sales_paid, 0) AS c_prior_qtd_sales, COALESCE(pp.prior_qtd_retention_paid,0) AS c_prior_qtd_retention, CASE WHEN r.shares_eligible THEN COALESCE(sr.avg_13wk, 0) ELSE 0 END AS c_avg_13wk, CASE WHEN r.shares_eligible THEN COALESCE(sr.avg_4wk, 0) ELSE 0 END AS c_avg_4wk, CASE WHEN r.shares_eligible THEN COALESCE(rpx.net_points, 0) ELSE 0 END AS c_net_points, COALESCE(rpx.gross_points, 0) AS c_gross_points, COALESCE(rpx.missed_pct, 0) AS c_missed_pct, COALESCE(rpx.reduction_pct, 0) AS c_reduction_pct, CASE WHEN r.shares_eligible THEN COALESCE(wf.weighted_hours, 0) ELSE 0 END AS c_weighted_hours, wf.retention_weight_role, wf.retention_weight_location, wf.retention_weight_tenure, wf.retention_weight_license, r.license_pc FROM roster r LEFT JOIN base_qtd b ON b.tm_id = r.id LEFT JOIN actual_base_this_week abt ON abt.tm_id = r.id LEFT JOIN actuals_through_current a ON a.tm_id = r.id LEFT JOIN commission_qtd cq ON cq.tm_id = r.id LEFT JOIN bonus_paid_prior_qtd bpp ON bpp.tm_id = r.id LEFT JOIN mgr_bonus_qtd mq ON mq.tm_id = r.id LEFT JOIN prior_paid pp ON pp.tm_id = r.id LEFT JOIN sp_rolling sr ON sr.tm_id = r.id LEFT JOIN wh_final wf ON wf.tm_id = r.id LEFT JOIN retention_pts rpx ON rpx.tm_id = r.id),
  team_totals AS (SELECT SUM(c.c_qtd_base_paid) AS qtd_base_paid_total, SUM(c.c_qtd_base_in_pool) AS qtd_base_in_pool_total, SUM(c.c_qtd_growth_budget) AS qtd_growth_budget_total, SUM(c.c_qtd_mgr) AS qtd_mgr_total, SUM(c.c_qtd_hdb) AS qtd_hdb_total, SUM(c.c_qtd_comm) AS qtd_comm_total, SUM(c.c_qtd_bonus_paid_prior) AS qtd_bonus_paid_prior_total, SUM(c.c_curr_qtd_sp) AS qtd_sp_total, SUM(CASE WHEN c.r_role_category = 'Sales' THEN c.c_curr_qtd_sp ELSE 0 END) AS qtd_sp_sales_only, SUM(c.c_avg_13wk) AS team_avg_13wk, SUM(c.c_avg_4wk) AS team_avg_4wk, SUM(CASE WHEN c.license_pc THEN c.c_avg_13wk ELSE 0 END) AS team_avg_13wk_licensed, SUM(CASE WHEN c.license_pc THEN c.c_avg_4wk ELSE 0 END) AS team_avg_4wk_licensed, SUM(c.c_curr_comm) AS curr_comm_total, SUM(c.c_weighted_hours) AS wh_total, SUM(c.c_net_points) AS rp_total, SUM(COALESCE(c.weekly_health_benefit_agency_paid, 0)) AS team_weekly_health, SUM(c.c_health_qtd) AS qtd_health_total_exact, COALESCE(jsonb_agg(jsonb_build_object('team_member_id', c.tm_id, 'name', c.first_name || ' ' || c.last_name, 'weekly_health', COALESCE(c.weekly_health_benefit_agency_paid, 0)) ORDER BY c.first_name) FILTER (WHERE c.in_week), '[]'::jsonb) AS per_person_health_detail FROM combined c),
  departure_recapture AS (
    /* Departure recapture (Peter 2026-09-06). Freed base of a teammate who left is held back from
       the pool: design base x uncovered Mon-Fri workdays x tenure_mult at departure, easing
       straight-line to 0 over 52 weeks. The new-hire growth budget in reverse. Forward-only. */
    SELECT COALESCE(SUM(
      (CASE WHEN r.pay_type = 'SALARY' THEN r.pay_rate WHEN r.pay_type = 'HOURLY' THEN r.pay_rate * 40 ELSE 0 END)
      * (1 - public.team_week_base_fraction(p_agency_id, r.id, r.start_date, r.end_date, cw.week_end_date))
      * LEAST(1.00, GREATEST(0, FLOOR((r.end_date - COALESCE(r.start_date, r.end_date))::numeric / 7.0) / 52.0))
      * GREATEST(0, 1 - FLOOR((cw.week_end_date - r.end_date)::numeric / 7.0) / 52.0)
    ), 0) AS qtd_departure_recapture
    FROM roster r CROSS JOIN cycle_weeks cw
    WHERE r.end_date IS NOT NULL AND r.end_date >= v_recapture_from AND r.end_date < cw.week_end_date AND r.pay_rate IS NOT NULL),
  pool_calc_pre AS (SELECT tt.*, pwq.*, dr.qtd_departure_recapture, v_qtd_envelope AS qtd_envelope, v_qtd_wc AS qtd_wc, tt.qtd_health_total_exact AS qtd_health_total, ((v_qtd_envelope - v_qtd_wc - tt.qtd_health_total_exact) / (1.0 + v_burden_mult) - tt.qtd_base_in_pool_total - dr.qtd_departure_recapture - (CASE WHEN v_accrual_applies THEN v_comm_charge ELSE tt.qtd_comm_total END) - tt.qtd_mgr_total - v_qtd_hdb_max - pwq.qtd_prize_cart - pwq.qtd_wtq_trip - pwq.qtd_goals_total - tt.qtd_bonus_paid_prior_total) AS pre_reserve_pool_raw FROM team_totals tt CROSS JOIN prize_wtq_qtd pwq CROSS JOIN departure_recapture dr),
  pool_calc AS (SELECT pcp.*, (CASE WHEN v_accrual_applies THEN GREATEST(0, v_reserve_rate * (pcp.qtd_bonus_paid_prior_total + GREATEST(0, pcp.pre_reserve_pool_raw)) * v_reserve_decay) ELSE 0 END) AS qtd_reserve_held, GREATEST(0, GREATEST(0, pcp.pre_reserve_pool_raw) - (CASE WHEN v_accrual_applies THEN GREATEST(0, v_reserve_rate * (pcp.qtd_bonus_paid_prior_total + GREATEST(0, pcp.pre_reserve_pool_raw)) * v_reserve_decay) ELSE 0 END)) AS qtd_bonus_pool, pcp.pre_reserve_pool_raw AS qtd_bonus_pool_raw FROM pool_calc_pre pcp),
  pool_floor AS (SELECT pc.*, GREATEST(0, pc.qtd_bonus_pool_raw + COALESCE(pc.curr_comm_total, 0)) AS pre_commission_pool, CASE WHEN v_retention_floor_factor IS NULL THEN pc.qtd_bonus_pool / 3.0 ELSE GREATEST(pc.qtd_bonus_pool / 3.0, GREATEST(0, pc.qtd_bonus_pool_raw + COALESCE(pc.curr_comm_total, 0)) / 3.0 * v_retention_floor_factor) END AS ret_pool_resolved FROM pool_calc pc),
  pool_split AS (SELECT pf.*, pf.ret_pool_resolved AS qtd_retention_pool, GREATEST(0, pf.qtd_bonus_pool - pf.ret_pool_resolved) / 2.0 AS qtd_sp_13wk_pool, GREATEST(0, pf.qtd_bonus_pool - pf.ret_pool_resolved) / 2.0 AS qtd_sp_4wk_pool FROM pool_floor pf),
  distributed AS (SELECT c.*, ps.*,
    CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END AS hours_share_ratio,
    CASE WHEN ps.rp_total > 0 THEN c.c_net_points / ps.rp_total ELSE 0 END AS points_share_ratio,
    CASE WHEN v_points_mode THEN (CASE WHEN ps.rp_total > 0 THEN c.c_net_points / ps.rp_total ELSE 0 END) ELSE (CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END) END AS ret_share_ratio,
    /* THIS WEEK's points only (fixed 2026-09-26). The pool is already net of every bonus paid earlier in the cycle, so earlier weeks' points were paid out of their own weeks; the cycle-to-date guarantee built 2026-09-18 paid them a second time. */ CASE WHEN v_points_mode THEN c.c_net_points ELSE 0 END AS ret_guarantee,
    CASE WHEN c.license_pc AND ps.team_avg_13wk_licensed > 0 THEN c.c_avg_13wk / ps.team_avg_13wk_licensed ELSE 0 END AS sp13_share_ratio, CASE WHEN c.license_pc AND ps.team_avg_4wk_licensed > 0 THEN c.c_avg_4wk / ps.team_avg_4wk_licensed ELSE 0 END AS sp4_share_ratio FROM combined c CROSS JOIN pool_split ps),
  ret_calc AS (SELECT d.*,
    /* points mode: every net point is a dollar, guaranteed; whatever is left of the retention third after all point dollars is split by points share (equivalent to GREATEST(guarantee, share × third)). hours mode: weighted-hours share of the third. */
    CASE WHEN v_points_mode THEN d.ret_guarantee + d.ret_share_ratio * GREATEST(0, d.qtd_retention_pool - d.rp_total) ELSE d.ret_share_ratio * d.qtd_retention_pool END AS qtd_ret_earned,
    /* the part of the guarantee the third could not fund; agency-covered, never clawed back from the later pool (see bonus_paid_by_week) */
    CASE WHEN v_points_mode THEN GREATEST(0, d.ret_guarantee - d.ret_share_ratio * d.qtd_retention_pool) ELSE 0 END AS qtd_ret_topup
    FROM distributed d),
  earned AS (SELECT d.*, d.sp13_share_ratio * d.qtd_sp_13wk_pool AS qtd_sp13_earned, d.sp4_share_ratio * d.qtd_sp_4wk_pool AS qtd_sp4_earned, (d.qtd_ret_earned + d.sp13_share_ratio * d.qtd_sp_13wk_pool + d.sp4_share_ratio * d.qtd_sp_4wk_pool) AS qtd_bonus_earned, (d.sp13_share_ratio * d.qtd_sp_13wk_pool + d.sp4_share_ratio * d.qtd_sp_4wk_pool) AS qtd_sales_share, d.qtd_ret_earned AS qtd_retention_share FROM ret_calc d),
  locked_pay AS (SELECT pd.team_member_id AS tm_id, SUM((kv.value->>'period')::numeric) AS paid_bonus FROM public.weekly_pool_lock wl JOIN public.payroll_runs pr ON pr.pay_period_end = wl.week_end_date JOIN public.payroll_detail pd ON pd.payroll_run_id = pr.id AND pd.agency_id = p_agency_id CROSS JOIN LATERAL jsonb_each(COALESCE(pd.raw_earnings->'items', '{}'::jsonb)) kv WHERE wl.agency_id = p_agency_id AND wl.week_end_date = p_week_end_date AND kv.key ILIKE '%Team%' GROUP BY pd.team_member_id),
  settled AS (SELECT e.*, COALESCE(lp.paid_bonus, GREATEST(0, e.qtd_bonus_earned)) AS this_week_bonus, CASE WHEN lp.paid_bonus IS NOT NULL AND (GREATEST(0, e.qtd_sales_share) + GREATEST(0, e.qtd_retention_share)) > 0 THEN lp.paid_bonus * GREATEST(0, e.qtd_sales_share) / (GREATEST(0, e.qtd_sales_share) + GREATEST(0, e.qtd_retention_share)) ELSE GREATEST(0, e.qtd_sales_share) END AS this_week_sales_share, CASE WHEN lp.paid_bonus IS NOT NULL AND (GREATEST(0, e.qtd_sales_share) + GREATEST(0, e.qtd_retention_share)) > 0 THEN lp.paid_bonus * GREATEST(0, e.qtd_retention_share) / (GREATEST(0, e.qtd_sales_share) + GREATEST(0, e.qtd_retention_share)) ELSE GREATEST(0, e.qtd_retention_share) END AS this_week_retention_share FROM earned e LEFT JOIN locked_pay lp ON lp.tm_id = e.tm_id),
  weekly_pool_totals AS (SELECT SUM(this_week_sales_share) AS weekly_sales_pool_sum, SUM(this_week_retention_share) AS weekly_retention_pool_sum, SUM(this_week_bonus) AS weekly_bonus_pool_sum FROM settled)
  SELECT s.tm_id, (s.first_name || ' ' || s.last_name)::text, s.r_role::text, s.r_role_category::text, s.r_role_level::text,
    ROUND(CASE WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 52 WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40 * 52 ELSE 0 END, 2) AS annual_base_salary,
    ROUND(s.c_actual_base_this_week, 2) AS weekly_base_salary,
    ROUND(s.c_curr_qtd_sp * 4, 2) AS annual_commission_projected, ROUND(s.c_curr_comm, 2) AS weekly_commission_projected, ROUND(s.c_curr_qtd_sp, 2) AS ytd_sales_points,
    ROUND(CASE WHEN (s.team_avg_13wk + s.team_avg_4wk) > 0 THEN (s.c_avg_13wk + s.c_avg_4wk) / (s.team_avg_13wk + s.team_avg_4wk) ELSE 0 END * 100, 4) AS sales_points_share_pct,
    ROUND(s.c_weighted_hours, 4) AS weighted_hours_at_40, ROUND(s.hours_share_ratio * 100, 4) AS retention_hours_share_pct,
    ROUND(s.c_net_points, 2) AS retention_net_points, ROUND(s.points_share_ratio * 100, 4) AS retention_points_share_pct, ROUND(s.ret_guarantee, 2) AS weekly_retention_guarantee, ROUND(s.qtd_ret_topup, 2) AS weekly_retention_topup,
    ROUND(CASE WHEN s.qtd_bonus_pool > 0 THEN s.qtd_bonus_earned / s.qtd_bonus_pool ELSE 0 END * 100, 4) AS person_share_pct,
    ROUND(s.qtd_bonus_earned * 4, 2) AS annual_bonus, ROUND(s.this_week_bonus, 2) AS weekly_bonus, ROUND(s.this_week_sales_share, 2) AS weekly_sales_pool_share, ROUND(s.this_week_retention_share, 2) AS weekly_retention_pool_share,
    ROUND(CASE WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 52 WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40 * 52 ELSE 0 END + s.c_curr_qtd_sp * 4 + s.qtd_bonus_earned * 4, 2) AS annual_total_comp,
    ROUND(s.c_actual_base_this_week + s.c_curr_comm + s.this_week_bonus, 2) AS weekly_total_comp,
    jsonb_build_object(
      'commission_semantic', 'qtd_commission from payroll_detail keys ILIKE %Comm% where pay_date <= week_end (prior weeks actually paid). Current-week fallback: LIVE SP-delta (this-week QTD SP minus most recent prior-week QTD SP within cycle) — bypasses wctd.commission to avoid one-cycle lag from team check-ins. Eats WHOLE pool.',
      'manager_bonus_semantic', 'qtd_manager_bonus from payroll_detail keys ILIKE %Manage% where pay_date <= week_end, with wctd.manager_bonus fallback for current week.',
      'base_semantic', 'qtd_actual_base_paid from payroll_detail SALARY+REGULAR+HOURLY+PTO where pay_date <= week_end (prior weeks actually paid), with get_weekly_cpr_hours (worked + PTO) or design-rate fallback for current week (not yet paid). PTO included as base-equivalent per Peter directive, in the paid line items and in the fallback alike (2026-09-15).',
      'design_note', '2026-07-25: current-week commission fallback rewired to live SP-delta (bypasses wctd.commission which lagged one write cycle behind team check-ins updating sales_points). Applies to both comm_by_week QTD sum and actuals_through_current.current_week_comm display.',
      'departed_this_week', s.left_in_week, 'shares_eligible', s.shares_eligible,
      'person_pay_type', s.pay_type, 'person_pay_rate', s.pay_rate, 'actual_base_this_week', ROUND(s.c_actual_base_this_week, 2),
      'retention_points', jsonb_build_object('mode', CASE WHEN v_points_mode THEN 'points' ELSE 'hours' END, 'go_live_week_end', v_rp_go_live, 'net_points', ROUND(s.c_net_points, 2), 'gross_points', ROUND(s.c_gross_points, 2), 'missed_pct', s.c_missed_pct, 'reduction_pct', s.c_reduction_pct, 'team_net_points', ROUND(s.rp_total, 2), 'points_share_pct', ROUND(s.points_share_ratio * 100, 4), 'guarantee_dollars', ROUND(s.ret_guarantee, 2), 'retention_third', ROUND(s.qtd_retention_pool, 2), 'pool_remainder_after_guarantees', ROUND(CASE WHEN v_points_mode THEN GREATEST(0, s.qtd_retention_pool - s.rp_total) ELSE 0 END, 2), 'pool_share_dollars', ROUND(CASE WHEN v_points_mode THEN s.qtd_ret_earned - s.ret_guarantee ELSE 0 END, 2), 'agency_topup_dollars', ROUND(s.qtd_ret_topup, 2), 'formula', 'points mode: retention dollars = net points (one point is one dollar, guaranteed) + points share × max(0, retention third − team net points); shortfall above the third is agency-covered and excluded from later weeks'' prior-paid subtraction. hours mode (weeks before go-live): weighted-hours share of the third.'),
      'weight_factors', jsonb_build_object('hours_baseline', 40.0, 'role_w', s.retention_weight_role, 'location_w', s.retention_weight_location, 'tenure_w', s.retention_weight_tenure, 'license_w', s.retention_weight_license),
      'quarter', jsonb_build_object('year', v_year, 'quarter', v_quarter, 'pool_start', v_cycle_start, 'pool_end', v_cycle_end, 'weeks_elapsed_qtd', v_week_of_cycle, 'weeks_in_quarter', v_weeks_in_cycle),
      'envelope', jsonb_build_object('annual_basis', ROUND(v_annual_basis, 2), 'current_pool_pct', v_current_pool_pct, 'weekly_envelope', ROUND(v_weekly_envelope, 2), 'qtd_envelope', ROUND(s.qtd_envelope, 2), 'quarterly_envelope', ROUND(v_cycle_envelope, 2)),
      'qtd_subtractions', jsonb_build_object(
        'qtd_wc', ROUND(s.qtd_wc, 2),
        'qtd_actual_health', ROUND(s.qtd_health_total, 2),
        'qtd_manager_bonus_actual', ROUND(s.qtd_mgr_total, 2),
        'qtd_manager_bonus_source', 'payroll_detail keys ILIKE %Manage% (pay_date <= week_end); wctd.manager_bonus fallback for current week',
        'qtd_hdb_actual', ROUND(s.qtd_hdb_total, 2),
        'qtd_hdb_max_accrual', ROUND(v_qtd_hdb_max, 2),
        'qtd_prize_cart_accrual', ROUND(s.qtd_prize_cart, 2),
        'qtd_wtq_trip_accrual', ROUND(s.qtd_wtq_trip, 2),
        'qtd_goals_total_accrual', ROUND(s.qtd_goals_total, 2),
        'qtd_wtw_bonus_accrual', ROUND(s.qtd_wtw_bonus, 2),
        'qtd_gain_bonus_accrual', ROUND(s.qtd_gain_bonus, 2),
        'qtd_leaderboard_bonus_accrual', ROUND(s.qtd_leaderboard_bonus, 2),
        'qtd_all_star_bonus_accrual', ROUND(s.qtd_all_star_bonus, 2),
        'qtd_trailblazer_bonus_accrual', ROUND(s.qtd_trailblazer_bonus, 2),
        'qtd_base_in_pool', ROUND(s.qtd_base_in_pool_total, 2),
        'qtd_departure_recapture', ROUND(s.qtd_departure_recapture, 2),
        'qtd_departure_recapture_source', 'freed base of a teammate who left (design base x uncovered workdays x tenure_mult at departure) held back from the pool, easing straight-line to 0 over 52 weeks; the new-hire growth budget in reverse; forward-only from 2026-08-30 departures',
        'qtd_actual_base_paid', ROUND(s.qtd_base_paid_total, 2),
        'qtd_actual_base_source', 'payroll_detail SALARY+REGULAR+HOURLY+PTO (pay_date <= week_end); get_weekly_cpr_hours worked+PTO, or design-rate, fallback for current week',
        'qtd_growth_budget', ROUND(s.qtd_growth_budget_total, 2),
        'qtd_actual_commission', ROUND(s.qtd_comm_total, 2),
        'qtd_actual_commission_source', 'payroll_detail keys ILIKE %Comm% (pay_date <= week_end); LIVE SP-delta fallback for current week (bypasses wctd.commission); eats WHOLE pool',
        'qtd_bonus_paid_prior', ROUND(s.qtd_bonus_paid_prior_total, 2),
        'qtd_bonus_paid_prior_source', 'payroll_detail keys ILIKE %Team% (pay_date <= week_end); wctd.bonus fallback per prior week; subtracted at envelope level',
        'qtd_burden', ROUND((s.qtd_base_in_pool_total + s.qtd_departure_recapture + s.qtd_comm_total + s.qtd_mgr_total + v_qtd_hdb_max + s.qtd_prize_cart + s.qtd_wtq_trip + s.qtd_goals_total + s.qtd_bonus_paid_prior_total + s.qtd_bonus_pool) * v_burden_mult, 2)
      ),
      'qtd_pools', jsonb_build_object(
        'qtd_bonus_pool', ROUND(s.qtd_bonus_pool, 2),
        'qtd_bonus_pool_semantic', 'This-week remaining after prior bonuses subtracted; not full cycle pool',
        'qtd_retention_pool', ROUND(s.qtd_retention_pool, 2),
        'retention_points_mode', CASE WHEN v_points_mode THEN 'points' ELSE 'hours' END, 'retention_points_team_net', ROUND(s.rp_total, 2), 'retention_guarantee_team_total', ROUND(CASE WHEN v_points_mode THEN s.rp_total ELSE 0 END, 2), 'retention_topup_team_total', ROUND((SELECT COALESCE(SUM(x.qtd_ret_topup), 0) FROM settled x), 2),
        'qtd_sp_13wk_pool', ROUND(s.qtd_sp_13wk_pool, 2),
        'qtd_sp_4wk_pool', ROUND(s.qtd_sp_4wk_pool, 2),
        'split_thirds', true,
        'retention_floor_factor', s.qtd_bonus_pool * 0 + v_retention_floor_factor,
        'retention_floor_basis_commissions', ROUND(COALESCE(s.curr_comm_total, 0), 2),
        'retention_floor_applied', (v_retention_floor_factor IS NOT NULL AND s.qtd_retention_pool > (s.qtd_bonus_pool / 3.0) + 0.005),
        'retention_floor_detail', v_retention_floor_diag,
        'retention_floor_raw', CASE WHEN v_retention_floor_factor IS NULL THEN NULL ELSE ROUND(s.pre_commission_pool / 3.0 * v_retention_floor_factor, 2) END,
        'pre_commission_pool', ROUND(s.pre_commission_pool, 2),
        'qtd_bonus_pool_raw', ROUND(s.qtd_bonus_pool_raw, 2),
        'retention_normal_third', ROUND(s.qtd_bonus_pool / 3.0, 2)
      ),
      'weekly_settlement', jsonb_build_object('weekly_sales_pool', ROUND((SELECT weekly_sales_pool_sum FROM weekly_pool_totals), 2), 'weekly_retention_pool', ROUND((SELECT weekly_retention_pool_sum FROM weekly_pool_totals), 2), 'weekly_bonus_pool', ROUND((SELECT weekly_bonus_pool_sum FROM weekly_pool_totals), 2)),
      'weekly_sales_pool', ROUND((SELECT weekly_sales_pool_sum FROM weekly_pool_totals), 2),
      'weekly_retention_pool', ROUND((SELECT weekly_retention_pool_sum FROM weekly_pool_totals), 2),
      'carveouts_outside_pool', jsonb_build_object(
        'annual_dollars', ROUND((v_weekly_apparel + v_weekly_life_ins + v_weekly_cc_reserve) * 52, 2),
        'quarterly_dollars', ROUND((v_weekly_apparel + v_weekly_life_ins + v_weekly_cc_reserve) * 13, 2),
        'weekly_dollars', ROUND(v_weekly_apparel + v_weekly_life_ins + v_weekly_cc_reserve, 2),
        'qtd_dollars', ROUND(v_qtd_apparel + v_qtd_life_ins + v_qtd_cc_reserve, 2),
        'note', 'Agency-funded team benefits outside residual pool.',
        'items', jsonb_build_object(
          'apparel', jsonb_build_object('weekly_dollars', ROUND(v_weekly_apparel, 2), 'qtd_dollars', ROUND(v_qtd_apparel, 2), 'annual_dollars', ROUND(v_weekly_apparel * 52, 2)),
          'life_insurance_stipend', jsonb_build_object('weekly_dollars', ROUND(v_weekly_life_ins, 2), 'qtd_dollars', ROUND(v_qtd_life_ins, 2), 'annual_dollars', ROUND(v_weekly_life_ins * 52, 2)),
          'champions_circle_reserve', jsonb_build_object('weekly_dollars', ROUND(v_weekly_cc_reserve, 2), 'qtd_dollars', ROUND(v_qtd_cc_reserve, 2), 'annual_dollars', ROUND(v_weekly_cc_reserve * 52, 2))
        )
      ),
      'team_totals', jsonb_build_object(
        'qtd_actual_base_paid', ROUND(s.qtd_base_paid_total, 2),
        'qtd_base_in_pool', ROUND(s.qtd_base_in_pool_total, 2),
        'qtd_growth_budget', ROUND(s.qtd_growth_budget_total, 2),
        'qtd_actual_health', ROUND(s.qtd_health_total, 2),
        'team_weekly_health', ROUND(s.team_weekly_health, 2),
        'per_person_health', s.per_person_health_detail,
        'qtd_actual_commission', ROUND(s.qtd_comm_total, 2),
        'qtd_bonus_paid_prior', ROUND(s.qtd_bonus_paid_prior_total, 2),
        'qtd_manager_bonus', ROUND(s.qtd_mgr_total, 2),
        'qtd_hdb', ROUND(s.qtd_hdb_total, 2),
        'qtd_sp_total', ROUND(s.qtd_sp_total, 2),
        'qtd_sp_sales_only', ROUND(s.qtd_sp_sales_only, 2),
        'team_avg_13wk', ROUND(s.team_avg_13wk, 2),
        'team_avg_4wk', ROUND(s.team_avg_4wk, 2),
        'wh_total', ROUND(s.wh_total, 4)
      ),
      'person_qtd', jsonb_build_object('qtd_actual_base_paid', ROUND(s.c_qtd_base_paid, 2), 'qtd_base_in_pool', ROUND(s.c_qtd_base_in_pool, 2), 'qtd_growth_budget', ROUND(s.c_qtd_growth_budget, 2), 'actual_base_this_week', ROUND(s.c_actual_base_this_week, 2), 'qtd_manager_bonus', ROUND(s.c_qtd_mgr, 2), 'qtd_hdb', ROUND(s.c_qtd_hdb, 2), 'qtd_commission', ROUND(s.c_qtd_comm, 2), 'qtd_bonus_paid_prior', ROUND(s.c_qtd_bonus_paid_prior, 2), 'qtd_sp', ROUND(s.c_curr_qtd_sp, 2), 'rolling_13wk_avg_sp', ROUND(s.c_avg_13wk, 2), 'rolling_4wk_avg_sp', ROUND(s.c_avg_4wk, 2), 'qtd_ret_earned', ROUND(s.qtd_ret_earned, 2), 'qtd_sp13_earned', ROUND(s.qtd_sp13_earned, 2), 'qtd_sp4_earned', ROUND(s.qtd_sp4_earned, 2), 'qtd_sales_share', ROUND(s.qtd_sales_share, 2), 'qtd_retention_share', ROUND(s.qtd_retention_share, 2), 'qtd_bonus_earned', ROUND(s.qtd_bonus_earned, 2), 'prior_qtd_bonus_paid', ROUND(s.c_prior_qtd_bonus, 2), 'prior_qtd_sales_paid', ROUND(s.c_prior_qtd_sales, 2), 'prior_qtd_retention_paid', ROUND(s.c_prior_qtd_retention, 2), 'this_week_bonus_settlement', ROUND(s.this_week_bonus, 2), 'this_week_sales_settlement', ROUND(s.this_week_sales_share, 2), 'this_week_retention_settlement', ROUND(s.this_week_retention_share, 2), 'ret_share_ratio_pct', ROUND(s.ret_share_ratio * 100, 4), 'sp13_share_ratio_pct', ROUND(s.sp13_share_ratio * 100, 4), 'sp4_share_ratio_pct', ROUND(s.sp4_share_ratio * 100, 4)),
      'constants', jsonb_build_object('sales_weight', 0.6667, 'retention_weight', 0.3333, 'burden_multiplier', v_burden_mult, 'wc_annual', v_wc_annual, 'split_thirds', true),
      'pool_basis', v_pool_result->'basis',
      'schedule', v_pool_result->'schedule',
      'carveouts_detail', v_carveouts_result
    )
  FROM settled s WHERE s.in_week ORDER BY s.last_name;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_weekly_crossings_live(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(kind text, category text, team_member_id uuid, value numeric, threshold numeric, tier integer, period_label text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cycle_start      date;
  v_cycle_end        date;
  v_is_quarter_close boolean;
  v_report_id        uuid;
  v_qtr_label        text;
BEGIN
  PERFORM public.require_login('staff');
  SELECT cci.cycle_start, cci.cycle_end, cci.quarter_label
    INTO v_cycle_start, v_cycle_end, v_qtr_label
  FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci;

  v_is_quarter_close := (v_cycle_end = p_week_end_date);

  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF v_report_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH cfg AS (
    SELECT c.category, c.round_step
    FROM public.leaderboard_floor_config c
    WHERE c.category <> 'quarter_sp' OR v_is_quarter_close
  ),
  -- The board as it stood BEFORE this week. The writer reads leaderboards right after
  -- reset_open_week_snapshots pulls this week's entries out, so the banner leaves this
  -- week's own entries out too. Otherwise a new record raises its own floor and hides
  -- the Trailblazer it earned.
  this_week AS (
    SELECT e.id
    FROM public.leaderboard_entries e
    WHERE e.agency_id = p_agency_id
      AND (e.record_week_ending = p_week_end_date
           OR (e.category = 'quarter_sp' AND v_is_quarter_close
               AND e.record_period_label = v_qtr_label))
  ),
  prior_board AS (
    SELECT e.category, e.record_value,
           ROW_NUMBER() OVER (PARTITION BY e.category ORDER BY e.record_value DESC, e.set_at DESC) AS rn
    FROM public.leaderboard_entries e
    WHERE e.agency_id = p_agency_id
      AND e.id NOT IN (SELECT tw.id FROM this_week tw)
  ),
  bounds AS (
    SELECT
      cfg.category,
      COALESCE(FLOOR(b.record_value / cfg.round_step) * cfg.round_step, 0) AS floor_val,
      COALESCE(CEIL((g.record_value + 0.01) / cfg.round_step) * cfg.round_step, 0) AS tb_thresh
    FROM cfg
    LEFT JOIN prior_board b ON b.category = cfg.category AND b.rn = 3
    LEFT JOIN prior_board g ON g.category = cfg.category AND g.rn = 1
  ),
  people AS (
    SELECT t.id
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.is_active = true
      AND t.archived_at IS NULL
      AND t.is_admin_backoffice = false
      AND (t.is_test_user IS NOT TRUE)
  ),
  vals AS (
    SELECT
      cfg.category,
      p.id AS tm_id,
      CASE cfg.category
        WHEN 'week_quotes' THEN
          COALESCE(
            (SELECT req.net_quotes
               FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_end_date) req
              WHERE req.team_member_id = p.id
              LIMIT 1),
            0)::numeric
        WHEN 'week_sp' THEN
          -- This week's earnings: quarter-to-date now, less quarter-to-date a week ago.
          GREATEST(0,
            COALESCE((SELECT f.sales_points
                        FROM public.sales_points_qtd_for(p_agency_id, p_week_end_date, p.id) f), 0)
            - CASE WHEN (p_week_end_date - 7) >= v_cycle_start
                   THEN COALESCE((SELECT f2.sales_points
                                    FROM public.sales_points_qtd_for(p_agency_id, (p_week_end_date - 7), p.id) f2), 0)
                   ELSE 0 END
          )
        WHEN 'four_week_sp' THEN
          public.compute_rolling_4wk_sp(p_agency_id, p_week_end_date, p.id)
        WHEN 'quarter_sp' THEN
          COALESCE((SELECT f.sales_points
                      FROM public.sales_points_qtd_for(p_agency_id, v_cycle_end, p.id) f), 0)
      END AS the_value
    FROM cfg CROSS JOIN people p
  )
  -- All-Star: cleared the bronze floor this week.
  SELECT 'all_star'::text, v.category, v.tm_id, v.the_value, b.floor_val, NULL::integer,
         to_char(p_week_end_date, 'Mon DD, YYYY')::text
  FROM vals v JOIN bounds b ON b.category = v.category
  WHERE b.floor_val > 0 AND v.the_value >= b.floor_val

  UNION ALL
  -- Trailblazer: cleared the current gold record this week.
  SELECT 'trailblazer'::text, v.category, v.tm_id, v.the_value, b.tb_thresh, NULL::integer,
         to_char(p_week_end_date, 'Mon DD, YYYY')::text
  FROM vals v JOIN bounds b ON b.category = v.category
  WHERE b.tb_thresh > 0 AND v.the_value >= b.tb_thresh

  UNION ALL
  -- Leaderboard record set this week — the record row stays where it is, but the
  -- number shown is recomputed from the rows as they stand now.
  SELECT 'leaderboard'::text, l.category, l.team_member_id,
         COALESCE(v.the_value, l.record_value), NULL::numeric, l.tier,
         l.record_period_label
  FROM public.leaderboards l
  LEFT JOIN vals v ON v.category = l.category AND v.tm_id = l.team_member_id
  WHERE l.agency_id = p_agency_id
    AND (l.record_week_ending = p_week_end_date
         -- Quarter records carry no week date; at the close week they belong on this banner.
         OR (l.category = 'quarter_sp' AND v_is_quarter_close
             AND l.record_period_label = v_qtr_label));
END;
$function$;
