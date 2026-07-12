-- Peter directive 2026-07-12 pm: 1% gain target should be 101% of prior-13-week avg SP.
-- Prior calc used LAG-delta over weekly_cpr_team_detail — broken because historical rows
-- store ONE quarter-end total per (person, quarter), so LAG returned NULL for isolated rows,
-- causing new_sp to equal the FULL quarter total (e.g. Tommy's Q2 $5,179.24 got treated as
-- one week's SP → target $5,231).
--
-- New rule: prior 13-week average = most recent COMPLETED quarter total / 13.
-- (Peter's "13 weeks" = 1 quarter by design; the SP History section already surfaces
-- quarterly totals to the user, so this stays consistent with what he sees on-screen.)

CREATE OR REPLACE FUNCTION public.write_weekly_comp_v2(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_rows_updated int := 0;
  v_wt_rows int := 0;
  v_report_id      uuid;
  v_won_the_week   boolean;
  v_mktg_result    jsonb;
  v_audit_result   jsonb;
  v_quarter_start  date;
  v_mvp_id         uuid;
  v_mvp_new_sp     numeric;
  v_mvp_draws      int;
  v_mvp_row_exists boolean;
  v_mvp_result     jsonb;
  v_goals_rows_updated int := 0;
  v_goals_detail   jsonb := '[]'::jsonb;
BEGIN
  SELECT id, won_the_week INTO v_report_id, v_won_the_week
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date
  LIMIT 1;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
      'rows_updated', 0,
      'note', 'no weekly_cpr_reports row exists for this week',
      'written_at', now()
    );
  END IF;

  v_quarter_start := date_trunc('quarter', p_week_end_date::timestamp)::date;

  WITH src AS (SELECT * FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date)),
       carveouts AS (SELECT public.compute_pool_carveouts(p_agency_id, p_week_end_date) AS data),
       hdb_by_person AS (
         SELECT (elem->>'team_member_id')::uuid AS team_id,
                (elem->>'weekly_max_dollars')::numeric AS weekly_max
         FROM carveouts, LATERAL jsonb_array_elements(carveouts.data->'health_development_bonus'->'detail') elem
       ),
       health_hits AS (
         SELECT team_id, hits
         FROM public.compute_team_health_weekly_hits(p_agency_id, p_week_end_date)
       ),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET base_salary = s.weekly_base_salary,
        commission  = s.weekly_commission_projected,
        bonus       = s.weekly_bonus,
        sales_pool_share     = s.weekly_sales_pool_share,
        retention_pool_share = s.weekly_retention_pool_share,
        manager_bonus = COALESCE(
          (SELECT (mgr->>'weekly_bonus_dollars')::numeric
           FROM jsonb_array_elements(
             COALESCE(s.diagnostics->'carveouts_detail'->'manager_bonus'->'detail', '[]'::jsonb)
           ) mgr
           WHERE mgr->>'team_member_id' = wctd.team_member_id::text
           LIMIT 1
          ), 0),
        health_bonus = CASE
          WHEN COALESCE((SELECT hits FROM health_hits hh WHERE hh.team_id = wctd.team_member_id), 0) >= 5
          THEN COALESCE((SELECT weekly_max FROM hdb_by_person hp WHERE hp.team_id = wctd.team_member_id), 0)
          ELSE 0
        END,
        residual_pool_diag = s.diagnostics || jsonb_build_object(
          'annual_base_salary', s.annual_base_salary,
          'annual_commission_projected', s.annual_commission_projected,
          'annual_bonus', s.annual_bonus,
          'annual_total_comp', s.annual_total_comp,
          'ytd_sales_points', s.ytd_sales_points,
          'sales_points_share_pct', s.sales_points_share_pct,
          'weighted_hours_at_40', s.weighted_hours_at_40,
          'retention_hours_share_pct', s.retention_hours_share_pct,
          'person_share_pct', s.person_share_pct),
        updated_at = now()
    FROM src s
    WHERE wctd.weekly_cpr_report_id = v_report_id AND wctd.team_member_id = s.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_rows_updated FROM upd;

  WITH wt AS (SELECT * FROM public.compute_warning_trigger(p_agency_id, p_week_end_date)),
  wt_upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET fully_loaded_annual         = w.fully_loaded_annual,
        attributed_revenue_annual   = w.attributed_revenue_annual,
        own_new_business_annualized = w.own_new_business_annualized,
        own_renewal_stack_credited  = w.own_renewal_stack_credited,
        retention_pool_share_annual = w.retention_pool_share_annual,
        retention_quality_multiplier = w.retention_quality_multiplier,
        coverage_bar                = w.coverage_bar,
        coverage_pct                = w.coverage_pct,
        coverage_status             = w.coverage_status,
        profitability_bar           = w.profitability_bar,
        profitability_pct           = w.profitability_pct,
        profitability_status        = w.profitability_status,
        lapse_rate_used             = w.lapse_rate_used,
        lapse_status                = w.lapse_status,
        renewal_stack_annual        = w.renewal_stack_annual,
        warning_bar           = w.warning_bar,
        warning_actual_annual = w.warning_actual_annual,
        warning_pct           = w.warning_pct,
        warning_status        = w.warning_status,
        warning_diag          = w.diag,
        updated_at            = now()
    FROM wt w
    WHERE wctd.weekly_cpr_report_id = v_report_id AND wctd.team_member_id = w.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_wt_rows FROM wt_upd;

  BEGIN
    v_mktg_result := public.write_weekly_marketing_bonus(p_agency_id, p_week_end_date);
  EXCEPTION WHEN OTHERS THEN
    v_mktg_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE);
  END;

  BEGIN
    v_audit_result := public.audit_weekly_leaderboard_crossings(p_agency_id, p_week_end_date);
  EXCEPTION WHEN OTHERS THEN
    v_audit_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE);
  END;

  -- ── GOALS BONUS (2026-07-12 v2) ─────────────────────────────────
  -- Per-person weekly $ = $10 × all_star_crossings row(s) this week
  --                     + $10 × trailblazer_crossings row(s) this week
  --                     + $10 if this-week new SP >= 1.01 × avg weekly SP of most recent completed quarter
  -- Runs AFTER audit so all_star_crossings + trailblazer_crossings for this week already inserted.
  --
  -- "avg weekly SP of most recent completed quarter" = (quarter_total / 13.0)
  -- Historical weekly_cpr_team_detail rows store one QTD row per (person, quarter) at quarter close,
  -- so quarter_total == max(sales_points) within the quarter (== the single stored value).
  BEGIN
    WITH curr AS (
      SELECT d.team_member_id, COALESCE(d.sales_points, 0)::numeric AS curr_qtd
      FROM public.weekly_cpr_team_detail d
      WHERE d.weekly_cpr_report_id = v_report_id
    ),
    prior_sat AS (
      SELECT DISTINCT ON (d.team_member_id) d.team_member_id, d.sales_points AS prior_qtd
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
      WHERE r.agency_id = p_agency_id
        AND r.week_ending_date < p_week_end_date
        AND r.week_ending_date >= v_quarter_start
      ORDER BY d.team_member_id, r.week_ending_date DESC
    ),
    this_new_sp AS (
      SELECT c.team_member_id,
             GREATEST(0, c.curr_qtd - COALESCE(ps.prior_qtd, 0))::numeric AS this_wk_new_sp
      FROM curr c LEFT JOIN prior_sat ps ON ps.team_member_id = c.team_member_id
    ),
    last_completed_q AS (
      SELECT DISTINCT ON (d.team_member_id)
        d.team_member_id,
        d.sales_points AS q_total,
        r.week_ending_date AS q_end_sat,
        date_trunc('quarter', r.week_ending_date::timestamp)::date AS q_start
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
      WHERE r.agency_id = p_agency_id
        AND d.sales_points IS NOT NULL
        AND date_trunc('quarter', r.week_ending_date::timestamp)::date < v_quarter_start
      ORDER BY d.team_member_id, r.week_ending_date DESC
    ),
    prior_avg AS (
      SELECT team_member_id,
             (q_total / 13.0)::numeric AS avg_new_sp,
             q_end_sat,
             q_total
      FROM last_completed_q
    ),
    as_counts AS (
      SELECT team_member_id, COUNT(*) AS n
      FROM public.all_star_crossings
      WHERE agency_id = p_agency_id AND week_ending = p_week_end_date
      GROUP BY team_member_id
    ),
    tb_counts AS (
      SELECT team_member_id, COUNT(*) AS n
      FROM public.trailblazer_crossings
      WHERE agency_id = p_agency_id AND week_ending = p_week_end_date
      GROUP BY team_member_id
    ),
    per_person AS (
      SELECT
        t.team_member_id,
        t.this_wk_new_sp,
        COALESCE(a.avg_new_sp, 0)::numeric AS avg_prior_13wk,
        COALESCE(a.q_total, 0)::numeric    AS ref_quarter_total,
        a.q_end_sat                        AS ref_quarter_end,
        COALESCE(a.avg_new_sp, 0)::numeric * 1.01 AS target_1pct,
        (COALESCE(a.avg_new_sp, 0) > 0 AND t.this_wk_new_sp >= COALESCE(a.avg_new_sp, 0) * 1.01) AS gain_hit,
        COALESCE(asc_.n, 0)::int AS as_hits,
        COALESCE(tb.n, 0)::int  AS tb_hits
      FROM this_new_sp t
      LEFT JOIN prior_avg a ON a.team_member_id = t.team_member_id
      LEFT JOIN as_counts asc_ ON asc_.team_member_id = t.team_member_id
      LEFT JOIN tb_counts tb   ON tb.team_member_id  = t.team_member_id
    ),
    with_dollars AS (
      SELECT p.*,
             (10 * (p.as_hits + p.tb_hits + CASE WHEN p.gain_hit THEN 1 ELSE 0 END))::numeric AS dollars
      FROM per_person p
    ),
    goals_upd AS (
      UPDATE public.weekly_cpr_team_detail wctd
      SET goals_bonus = w.dollars,
          residual_pool_diag = COALESCE(wctd.residual_pool_diag, '{}'::jsonb) || jsonb_build_object(
            'goals_detail', jsonb_build_object(
              'this_wk_new_sp',      ROUND(w.this_wk_new_sp, 2),
              'avg_prior_13wk',      ROUND(w.avg_prior_13wk, 2),
              'ref_quarter_total',   ROUND(w.ref_quarter_total, 2),
              'ref_quarter_end',     w.ref_quarter_end,
              'target_1pct',         ROUND(w.target_1pct, 2),
              'gain_hit',            w.gain_hit,
              'as_hits',             w.as_hits,
              'tb_hits',             w.tb_hits,
              'dollars',             w.dollars,
              'formula',             '$10 per All-Star crossing + $10 per Trailblazer crossing + $10 if this-week new SP >= 1.01 * (most recent completed quarter total / 13)'
            )
          ),
          updated_at = now()
      FROM with_dollars w
      WHERE wctd.weekly_cpr_report_id = v_report_id
        AND wctd.team_member_id = w.team_member_id
      RETURNING wctd.id, w.dollars, w.gain_hit, w.as_hits, w.tb_hits, w.this_wk_new_sp, w.target_1pct
    )
    SELECT COUNT(*), COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', id, 'dollars', dollars, 'as_hits', as_hits, 'tb_hits', tb_hits, 'gain_hit', gain_hit,
      'this_wk_new_sp', this_wk_new_sp, 'target_1pct', target_1pct
    )), '[]'::jsonb)
    INTO v_goals_rows_updated, v_goals_detail
    FROM goals_upd;
  EXCEPTION WHEN OTHERS THEN
    v_goals_detail := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE);
  END;

  -- ── MVP auto-detection ─────────────────────────────────────────
  v_mvp_result := jsonb_build_object('detected', false, 'reason', 'not evaluated');

  IF COALESCE(v_won_the_week, false) THEN
    SELECT EXISTS (
      SELECT 1 FROM public.mvp_history
       WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date
    ) INTO v_mvp_row_exists;

    IF v_mvp_row_exists THEN
      v_mvp_result := jsonb_build_object('detected', false, 'reason', 'mvp_history row already exists for this week');
    ELSE
      WITH curr AS (
        SELECT d.team_member_id, d.sales_points AS curr_qtd
        FROM public.weekly_cpr_team_detail d
        WHERE d.weekly_cpr_report_id = v_report_id AND d.sales_points IS NOT NULL
      ),
      prior AS (
        SELECT DISTINCT ON (d.team_member_id) d.team_member_id, d.sales_points AS prior_qtd
        FROM public.weekly_cpr_team_detail d
        JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
        WHERE r.agency_id = p_agency_id
          AND r.week_ending_date < p_week_end_date
          AND r.week_ending_date >= v_quarter_start
        ORDER BY d.team_member_id, r.week_ending_date DESC
      ),
      deltas AS (
        SELECT c.team_member_id,
               GREATEST(0, c.curr_qtd - COALESCE(p.prior_qtd, 0)) AS new_sp
        FROM curr c
        LEFT JOIN prior p ON p.team_member_id = c.team_member_id
      )
      SELECT team_member_id, new_sp INTO v_mvp_id, v_mvp_new_sp
      FROM deltas
      WHERE new_sp >= 100
      ORDER BY new_sp DESC
      LIMIT 1;

      IF v_mvp_id IS NOT NULL THEN
        v_mvp_draws := public.compute_mvp_prize_draws(p_agency_id, v_mvp_new_sp);
        INSERT INTO public.mvp_history (agency_id, week_ending_date, team_member_id, sales_points_earned, prize_draws)
        VALUES (p_agency_id, p_week_end_date, v_mvp_id, v_mvp_new_sp, v_mvp_draws);

        v_mvp_result := jsonb_build_object(
          'detected', true,
          'team_member_id', v_mvp_id,
          'new_sp', v_mvp_new_sp,
          'prize_draws', v_mvp_draws
        );
      ELSE
        v_mvp_result := jsonb_build_object('detected', false, 'reason', 'no teammate had >= 100 new SP this week');
      END IF;
    END IF;
  ELSE
    v_mvp_result := jsonb_build_object('detected', false, 'reason', 'team did not win the week');
  END IF;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
    'weekly_cpr_report_id', v_report_id,
    'rows_updated', v_rows_updated,
    'warning_trigger_rows_updated', v_wt_rows,
    'marketing_bonus_result',  v_mktg_result,
    'leaderboard_audit_result', v_audit_result,
    'goals_bonus_rows_updated', v_goals_rows_updated,
    'goals_bonus_detail',       v_goals_detail,
    'mvp_detection_result',    v_mvp_result,
    'written_at', now()
  );
END;
$function$;
