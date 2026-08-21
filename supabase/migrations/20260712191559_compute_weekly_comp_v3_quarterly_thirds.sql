-- Quarterly-input residual pool with 1/3 · 1/3 · 1/3 split.
-- Retention 1/3 = weighted-hours-this-week share.
-- Sales 1/3 (13wk) = rolling 13-wk earned SP average share.
-- Sales 1/3 (4wk) = rolling 4-wk earned SP average share.
-- All subtractions QTD-elapsed. Actuals where available; accrual otherwise.
-- Pre-hire weeks and pre-scale-change weeks (before 2026-07-05 Cycle 2 start) treated as 0 SP.
CREATE OR REPLACE FUNCTION public.compute_weekly_comp_v3(
  p_agency_id     uuid,
  p_week_end_date date
)
RETURNS TABLE (
  team_member_id           uuid,
  full_name                text,
  role                     text,
  role_category            text,
  role_level               text,
  weekly_base_salary       numeric,
  weekly_commission        numeric,
  qtd_sales_points         numeric,
  rolling_13wk_avg_sp      numeric,
  rolling_4wk_avg_sp       numeric,
  weighted_hours           numeric,
  retention_share_pct      numeric,
  sp_13wk_share_pct        numeric,
  sp_4wk_share_pct         numeric,
  qtd_retention_earned     numeric,
  qtd_sp_13wk_earned       numeric,
  qtd_sp_4wk_earned        numeric,
  qtd_bonus_earned         numeric,
  weekly_bonus             numeric,
  diagnostics              jsonb
)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_cycle_info          record;
  v_cycle_start         date;
  v_cycle_end           date;
  v_week_of_cycle       int;
  v_new_scale_cutover   CONSTANT date := '2026-07-05';  -- Cycle 2 Sunday start
  v_pool_result         jsonb;
  v_carveouts_result    jsonb;
  v_annual_basis        numeric;
  v_qtd_envelope        numeric;
  v_current_pool_pct    numeric;
  v_weekly_envelope     numeric;
  v_burden_mult         CONSTANT numeric := 0.08;
  v_wc_annual           CONSTANT numeric := 500.00;
  v_qtd_wc              numeric;
  -- Formula-based carveout WEEKLY dollars (× weeks_elapsed for QTD accrual)
  v_weekly_apparel      numeric;
  v_weekly_life_ins     numeric;
  v_weekly_cc_reserve   numeric;
  v_weekly_prize_cart   numeric;
  v_weekly_wtq_trip     numeric;
BEGIN
  -- 1. CYCLE BOUNDS
  SELECT cycle_start, cycle_end, week_of_cycle
  INTO v_cycle_start, v_cycle_end, v_week_of_cycle
  FROM public.current_cycle_info(p_agency_id, p_week_end_date);

  IF v_cycle_start IS NULL THEN
    RETURN;
  END IF;

  -- 2. ENVELOPE + BASIS
  v_pool_result      := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_carveouts_result := public.compute_pool_carveouts(p_agency_id, p_week_end_date);
  v_annual_basis     := COALESCE(NULLIF(v_pool_result->'basis'->>'total_basis_annual','')::numeric, 0);
  v_current_pool_pct := COALESCE(NULLIF(v_pool_result->'schedule'->>'pool_pct','')::numeric, 0);
  v_weekly_envelope  := (v_annual_basis * v_current_pool_pct / 100.0) / 52.0;

  -- QTD envelope = SUM of scheduled weekly envelopes for weeks_elapsed in current cycle
  SELECT COALESCE(SUM((v_annual_basis * pool_pct / 100.0) / 52.0), 0)
  INTO v_qtd_envelope
  FROM public.team_comp_pool_schedule
  WHERE agency_id = p_agency_id
    AND week_end_date >= v_cycle_start
    AND week_end_date <= p_week_end_date;

  -- 3. FORMULA-BASED CARVEOUT WEEKLY DOLLARS (accrual × weeks_elapsed = QTD subtraction)
  -- Manager Bonus + HDB use ACTUAL weekly values from weekly_cpr_team_detail (queried in main CTE below).
  v_weekly_apparel    := COALESCE(NULLIF(v_carveouts_result->'apparel'->>'weekly_dollars','')::numeric, 0);
  v_weekly_life_ins   := COALESCE(NULLIF(v_carveouts_result->'life_insurance_stipend'->>'weekly_dollars','')::numeric, 0);
  v_weekly_cc_reserve := COALESCE(NULLIF(v_carveouts_result->'champions_circle'->>'weekly_dollars','')::numeric, 0);
  v_weekly_prize_cart := COALESCE(NULLIF(v_carveouts_result->'mvp_prize_cart'->>'weekly_dollars','')::numeric, 0);
  v_weekly_wtq_trip   := COALESCE(NULLIF(v_carveouts_result->'wtq_trip'->>'weekly_dollars','')::numeric, 0);

  -- 4. WORKERS COMP QTD (500/yr → weekly × weeks_elapsed)
  v_qtd_wc := (v_wc_annual / 52.0) * v_week_of_cycle;

  RETURN QUERY
  WITH roster AS (
    SELECT et.team_id AS id, et.first_name, et.last_name,
           et.role AS r_role, et.role_category AS r_role_category, et.role_level AS r_role_level,
           t.pay_type, t.pay_rate, t.work_location, et.start_date,
           t.license_pc, t.license_lh, t.license_ips,
           t.weekly_health_benefit_agency_paid
    FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
    JOIN public.team t ON t.id = et.team_id
  ),
  cycle_weeks AS (
    SELECT week_end_date
    FROM public.team_comp_pool_schedule
    WHERE agency_id = p_agency_id
      AND week_end_date >= v_cycle_start
      AND week_end_date <= p_week_end_date
  ),
  -- Per-person, per-cycle-week base pay + tenure ramp (preserves new-hire growth budget)
  base_by_week AS (
    SELECT r.id AS tm_id, cw.week_end_date,
      COALESCE(
        (SELECT COALESCE((pd.raw_earnings->'items'->'SALARY' ->>'period')::numeric, 0)
              + COALESCE((pd.raw_earnings->'items'->'REGULAR'->>'period')::numeric, 0)
         FROM public.payroll_detail pd
         JOIN public.payroll_runs   pr ON pr.id = pd.payroll_run_id
         WHERE pd.agency_id = p_agency_id AND pd.team_member_id = r.id
           AND pr.pay_period_end = cw.week_end_date
         LIMIT 1),
        CASE
          WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate
          WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40
          ELSE 0
        END
      ) AS week_base_paid,
      LEAST(1.00, GREATEST(0,
        FLOOR((cw.week_end_date - r.start_date)::numeric / 7.0) / 52.0
      )) AS week_tenure_mult
    FROM roster r CROSS JOIN cycle_weeks cw
  ),
  base_qtd AS (
    SELECT tm_id,
      SUM(week_base_paid) AS qtd_base_paid,
      SUM(week_base_paid * week_tenure_mult) AS qtd_base_in_pool
    FROM base_by_week
    GROUP BY tm_id
  ),
  -- QTD actuals from weekly_cpr_team_detail rows in current cycle
  cpr_actuals_qtd AS (
    SELECT r.id AS tm_id,
      COALESCE(SUM(wctd.manager_bonus), 0)  AS qtd_manager_bonus_actual,
      COALESCE(SUM(wctd.health_bonus), 0)   AS qtd_hdb_actual,
      COALESCE(SUM(wctd.bonus), 0)          AS prior_qtd_bonus_paid,
      COALESCE(SUM(wctd.commission), 0)     AS qtd_commission_paid,
      MAX(CASE WHEN wr.week_ending_date = p_week_end_date THEN wctd.sales_points END) AS current_week_qtd_sp
    FROM roster r
    LEFT JOIN public.weekly_cpr_reports wr
      ON wr.agency_id = p_agency_id
     AND wr.week_ending_date >= v_cycle_start
     AND wr.week_ending_date <= p_week_end_date
    LEFT JOIN public.weekly_cpr_team_detail wctd
      ON wctd.weekly_cpr_report_id = wr.id
     AND wctd.team_member_id = r.id
    GROUP BY r.id
  ),
  -- Weekly earned SP series for rolling averages. Sources: weekly_cpr_team_detail (canonical) and
  -- team_checkins (fallback for weeks lacking CPR detail). Weekly earned = QTD delta within same cycle.
  -- Weeks before pre-hire OR before Cycle 2 (v_new_scale_cutover) = 0 for that person.
  weeks_series AS (
    -- Generate 13 Saturdays ending at p_week_end_date
    SELECT (p_week_end_date - (n * 7))::date AS week_ending, n AS lookback_idx
    FROM generate_series(0, 12) n
  ),
  cpr_qtd_by_week AS (
    SELECT r.id AS tm_id, wr.week_ending_date, wctd.sales_points AS qtd_sp
    FROM roster r
    JOIN public.weekly_cpr_reports wr
      ON wr.agency_id = p_agency_id
     AND wr.week_ending_date >= p_week_end_date - INTERVAL '13 weeks'
     AND wr.week_ending_date <= p_week_end_date
    JOIN public.weekly_cpr_team_detail wctd
      ON wctd.weekly_cpr_report_id = wr.id
     AND wctd.team_member_id = r.id
    WHERE wctd.sales_points IS NOT NULL
  ),
  weekly_earned AS (
    SELECT r.id AS tm_id, ws.week_ending, ws.lookback_idx,
      -- Only count weeks on or after Cycle 2 start (new scale)
      CASE
        WHEN ws.week_ending < v_new_scale_cutover + INTERVAL '6 days' THEN 0
        WHEN r.start_date IS NOT NULL AND ws.week_ending < r.start_date THEN 0
        ELSE
          GREATEST(0,
            COALESCE(cq.qtd_sp, 0)
            - COALESCE((
                SELECT cq2.qtd_sp
                FROM cpr_qtd_by_week cq2
                WHERE cq2.tm_id = r.id
                  AND cq2.week_ending < ws.week_ending
                  -- Same cycle only: ceiling week is prior Saturday. Use cycle_anchor_date arithmetic:
                  -- both weeks in same 13-wk cycle if (week - cycle_anchor) / 91 matches.
                  AND FLOOR((cq2.week_ending - (SELECT setting_value::date FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'cycle_anchor_date' LIMIT 1)) / 91) 
                    = FLOOR((ws.week_ending - (SELECT setting_value::date FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'cycle_anchor_date' LIMIT 1)) / 91)
                ORDER BY cq2.week_ending DESC
                LIMIT 1
              ), 0)
          )
      END AS weekly_earned_sp
    FROM roster r CROSS JOIN weeks_series ws
    LEFT JOIN cpr_qtd_by_week cq
      ON cq.tm_id = r.id AND cq.week_ending_date = ws.week_ending
    -- Rename for cq.week_ending_date reference (fixing column name mismatch)
  ),
  sp_rolling AS (
    SELECT tm_id,
      SUM(weekly_earned_sp) / 13.0 AS avg_13wk,
      SUM(CASE WHEN lookback_idx < 4 THEN weekly_earned_sp ELSE 0 END) / 4.0 AS avg_4wk
    FROM weekly_earned
    GROUP BY tm_id
  ),
  -- Weighted hours THIS WEEK per current op-rule (40 baseline × 5-factor)
  wh_calc AS (
    SELECT r.id AS tm_id,
      40.0 AS baseline_hours,
      CASE WHEN r.r_role = 'Reception' THEN 1.00
           WHEN r.r_role IN ('Acquisition', 'Inside Sales') THEN 0.25
           ELSE 0 END AS role_w,
      CASE WHEN r.work_location = 'in_office' THEN 1.00
           WHEN r.work_location = 'remote'    THEN 0.50
           ELSE 1.00 END AS location_w,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS tenure_w,
      LEAST(1.00, 0.50
           + CASE WHEN r.license_pc  THEN 0.35 ELSE 0 END
           + CASE WHEN r.license_lh  THEN 0.10 ELSE 0 END
           + CASE WHEN r.license_ips THEN 0.05 ELSE 0 END) AS license_w
    FROM roster r
  ),
  wh_final AS (
    SELECT tm_id,
      baseline_hours * role_w * location_w * tenure_w * license_w AS weighted_hours,
      role_w, location_w, tenure_w, license_w
    FROM wh_calc
  ),
  combined AS (
    SELECT r.id AS tm_id, r.first_name, r.last_name,
      r.r_role, r.r_role_category, r.r_role_level,
      r.pay_type, r.pay_rate, r.weekly_health_benefit_agency_paid,
      COALESCE(b.qtd_base_paid, 0)             AS c_qtd_base_paid,
      COALESCE(b.qtd_base_in_pool, 0)          AS c_qtd_base_in_pool,
      COALESCE(a.qtd_manager_bonus_actual, 0)  AS c_qtd_mgr_actual,
      COALESCE(a.qtd_hdb_actual, 0)            AS c_qtd_hdb_actual,
      COALESCE(a.prior_qtd_bonus_paid, 0)      AS c_prior_qtd_bonus_paid,
      COALESCE(a.qtd_commission_paid, 0)       AS c_qtd_commission_paid,
      COALESCE(a.current_week_qtd_sp, 0)       AS c_current_qtd_sp,
      COALESCE(sr.avg_13wk, 0)                 AS c_avg_13wk,
      COALESCE(sr.avg_4wk, 0)                  AS c_avg_4wk,
      COALESCE(wf.weighted_hours, 0)           AS c_weighted_hours,
      wf.role_w, wf.location_w, wf.tenure_w, wf.license_w
    FROM roster r
    LEFT JOIN base_qtd b ON b.tm_id = r.id
    LEFT JOIN cpr_actuals_qtd a ON a.tm_id = r.id
    LEFT JOIN sp_rolling sr ON sr.tm_id = r.id
    LEFT JOIN wh_final wf ON wf.tm_id = r.id
  ),
  team_totals AS (
    SELECT
      SUM(c.c_qtd_base_paid)         AS qtd_base_paid_total,
      SUM(c.c_qtd_base_in_pool)      AS qtd_base_in_pool_total,
      SUM(c.c_qtd_mgr_actual)        AS qtd_mgr_actual_total,
      SUM(c.c_qtd_hdb_actual)        AS qtd_hdb_actual_total,
      SUM(c.c_qtd_commission_paid)   AS qtd_commission_total,
      SUM(c.c_current_qtd_sp)        AS qtd_sp_total,
      SUM(c.c_avg_13wk)              AS team_avg_13wk,
      SUM(c.c_avg_4wk)               AS team_avg_4wk,
      SUM(c.c_weighted_hours)        AS wh_total,
      SUM(COALESCE(c.weekly_health_benefit_agency_paid, 0)) AS team_weekly_health
    FROM combined c
  ),
  -- QTD Carveout subtractions:
  --   Manager Bonus + HDB: actual sums from CPR detail (SUM of weekly stored values in cycle)
  --   Apparel, Life Ins, CC Reserve: weekly $ × weeks_elapsed (accrual)
  --   Prize Cart, WtQ Trip: weekly $ × weeks_elapsed (per Peter: elapsed/13 × quarterly)
  qtd_carveouts AS (
    SELECT
      tt.qtd_mgr_actual_total                       AS qtd_carve_mgr,
      tt.qtd_hdb_actual_total                       AS qtd_carve_hdb,
      v_weekly_apparel    * v_week_of_cycle         AS qtd_carve_apparel,
      v_weekly_life_ins   * v_week_of_cycle         AS qtd_carve_life,
      v_weekly_cc_reserve * v_week_of_cycle         AS qtd_carve_cc,
      v_weekly_prize_cart * v_week_of_cycle         AS qtd_carve_prize,
      v_weekly_wtq_trip   * v_week_of_cycle         AS qtd_carve_wtq
    FROM team_totals tt
  ),
  pool_calc AS (
    SELECT tt.*, qc.*,
      (qc.qtd_carve_mgr + qc.qtd_carve_hdb + qc.qtd_carve_apparel + qc.qtd_carve_life
       + qc.qtd_carve_cc + qc.qtd_carve_prize + qc.qtd_carve_wtq) AS qtd_carveouts_total,
      -- QTD health = weekly_health_benefit × weeks_elapsed (team total)
      tt.team_weekly_health * v_week_of_cycle AS qtd_health_total,
      v_qtd_envelope AS qtd_envelope,
      v_qtd_wc       AS qtd_wc
    FROM team_totals tt CROSS JOIN qtd_carveouts qc
  ),
  pool_math AS (
    SELECT pc.*,
      -- Bonus pool = (envelope - non-wage subtractions) / 1.08 - wage QTD subtractions
      -- Non-wage: WC, health, prize cart, WtQ trip (not payroll-burdened)
      -- Wage QTD: base, commission, mgr, hdb, apparel, life ins, cc reserve (all payroll)
      GREATEST(0,
        (pc.qtd_envelope
         - pc.qtd_wc
         - pc.qtd_health_total
         - pc.qtd_carve_prize
         - pc.qtd_carve_wtq
        ) / (1.0 + v_burden_mult)
        - pc.qtd_base_in_pool_total
        - pc.qtd_commission_total
        - pc.qtd_carve_mgr
        - pc.qtd_carve_hdb
        - pc.qtd_carve_apparel
        - pc.qtd_carve_life
        - pc.qtd_carve_cc
      ) AS qtd_bonus_pool
    FROM pool_calc pc
  ),
  pool_split AS (
    SELECT pm.*,
      pm.qtd_bonus_pool / 3.0 AS qtd_retention_pool,
      pm.qtd_bonus_pool / 3.0 AS qtd_sp_13wk_pool,
      pm.qtd_bonus_pool / 3.0 AS qtd_sp_4wk_pool
    FROM pool_math pm
  ),
  distributed AS (
    SELECT c.*, ps.*,
      CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END AS ret_share_ratio,
      CASE WHEN ps.team_avg_13wk > 0 THEN c.c_avg_13wk / ps.team_avg_13wk ELSE 0 END AS sp13_share_ratio,
      CASE WHEN ps.team_avg_4wk > 0 THEN c.c_avg_4wk / ps.team_avg_4wk ELSE 0 END AS sp4_share_ratio
    FROM combined c CROSS JOIN pool_split ps
  ),
  final AS (
    SELECT d.*,
      d.ret_share_ratio  * d.qtd_retention_pool AS qtd_ret_earned,
      d.sp13_share_ratio * d.qtd_sp_13wk_pool   AS qtd_sp13_earned,
      d.sp4_share_ratio  * d.qtd_sp_4wk_pool    AS qtd_sp4_earned,
      (d.ret_share_ratio * d.qtd_retention_pool
       + d.sp13_share_ratio * d.qtd_sp_13wk_pool
       + d.sp4_share_ratio  * d.qtd_sp_4wk_pool) AS qtd_bonus_earned
    FROM distributed d
  ),
  settled AS (
    SELECT f.*,
      GREATEST(0, f.qtd_bonus_earned - f.c_prior_qtd_bonus_paid) AS this_week_bonus
    FROM final f
  )
  SELECT
    s.tm_id,
    (s.first_name || ' ' || s.last_name)::text,
    s.r_role::text, s.r_role_category::text, s.r_role_level::text,
    ROUND(CASE
      WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate
      WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40
      ELSE 0
    END, 2) AS weekly_base_salary,
    ROUND(GREATEST(0, s.c_current_qtd_sp - COALESCE((
      SELECT wctd_p.sales_points
      FROM public.weekly_cpr_team_detail wctd_p
      JOIN public.weekly_cpr_reports wr_p ON wr_p.id = wctd_p.weekly_cpr_report_id
      WHERE wr_p.agency_id = p_agency_id
        AND wr_p.week_ending_date >= v_cycle_start
        AND wr_p.week_ending_date < p_week_end_date
        AND wctd_p.team_member_id = s.tm_id
      ORDER BY wr_p.week_ending_date DESC LIMIT 1
    ), 0)), 2) AS weekly_commission,
    ROUND(s.c_current_qtd_sp, 2)          AS qtd_sales_points,
    ROUND(s.c_avg_13wk, 2)                AS rolling_13wk_avg_sp,
    ROUND(s.c_avg_4wk, 2)                 AS rolling_4wk_avg_sp,
    ROUND(s.c_weighted_hours, 4)          AS weighted_hours,
    ROUND(s.ret_share_ratio * 100, 4)     AS retention_share_pct,
    ROUND(s.sp13_share_ratio * 100, 4)    AS sp_13wk_share_pct,
    ROUND(s.sp4_share_ratio * 100, 4)     AS sp_4wk_share_pct,
    ROUND(s.qtd_ret_earned, 2)            AS qtd_retention_earned,
    ROUND(s.qtd_sp13_earned, 2)           AS qtd_sp_13wk_earned,
    ROUND(s.qtd_sp4_earned, 2)            AS qtd_sp_4wk_earned,
    ROUND(s.qtd_bonus_earned, 2)          AS qtd_bonus_earned,
    ROUND(s.this_week_bonus, 2)           AS weekly_bonus,
    jsonb_build_object(
      'design_note',
        'v3 quarterly-input residual pool. Envelope + all subtractions QTD-elapsed. '
        || '1/3-1/3-1/3 split: retention weighted-hours (this week) + rolling-13wk SP avg + rolling-4wk SP avg. '
        || 'Pre-Cycle-2 (2026-07-05) weeks treated as 0 SP. Pre-hire weeks treated as 0.',
      'cycle', jsonb_build_object(
        'cycle_start',    v_cycle_start,
        'cycle_end',      v_cycle_end,
        'week_of_cycle',  v_week_of_cycle,
        'new_scale_cutover', v_new_scale_cutover
      ),
      'envelope', jsonb_build_object(
        'annual_basis',       ROUND(v_annual_basis, 2),
        'current_pool_pct',   v_current_pool_pct,
        'weekly_envelope',    ROUND(v_weekly_envelope, 2),
        'qtd_envelope',       ROUND(s.qtd_envelope, 2)
      ),
      'qtd_subtractions', jsonb_build_object(
        'qtd_wc',              ROUND(s.qtd_wc, 2),
        'qtd_base_in_pool',    ROUND(s.qtd_base_in_pool_total, 2),
        'qtd_actual_base_paid',ROUND(s.qtd_base_paid_total, 2),
        'qtd_commission',      ROUND(s.qtd_commission_total, 2),
        'qtd_health',          ROUND(s.qtd_health_total, 2),
        'qtd_carve_mgr_actual', ROUND(s.qtd_carve_mgr, 2),
        'qtd_carve_hdb_actual', ROUND(s.qtd_carve_hdb, 2),
        'qtd_carve_apparel',   ROUND(s.qtd_carve_apparel, 2),
        'qtd_carve_life_ins',  ROUND(s.qtd_carve_life, 2),
        'qtd_carve_cc_reserve',ROUND(s.qtd_carve_cc, 2),
        'qtd_carve_prize_cart',ROUND(s.qtd_carve_prize, 2),
        'qtd_carve_wtq_trip',  ROUND(s.qtd_carve_wtq, 2),
        'qtd_carveouts_total', ROUND(s.qtd_carveouts_total, 2)
      ),
      'pool', jsonb_build_object(
        'qtd_bonus_pool',      ROUND(s.qtd_bonus_pool, 2),
        'qtd_retention_pool',  ROUND(s.qtd_retention_pool, 2),
        'qtd_sp_13wk_pool',    ROUND(s.qtd_sp_13wk_pool, 2),
        'qtd_sp_4wk_pool',     ROUND(s.qtd_sp_4wk_pool, 2)
      ),
      'person', jsonb_build_object(
        'qtd_base_in_pool',        ROUND(s.c_qtd_base_in_pool, 2),
        'qtd_base_paid',           ROUND(s.c_qtd_base_paid, 2),
        'qtd_manager_bonus_actual',ROUND(s.c_qtd_mgr_actual, 2),
        'qtd_hdb_actual',          ROUND(s.c_qtd_hdb_actual, 2),
        'qtd_commission_paid',     ROUND(s.c_qtd_commission_paid, 2),
        'prior_qtd_bonus_paid',    ROUND(s.c_prior_qtd_bonus_paid, 2),
        'this_week_settlement',    ROUND(s.this_week_bonus, 2)
      ),
      'weight_factors', jsonb_build_object(
        'role_w',     s.role_w,
        'location_w', s.location_w,
        'tenure_w',   s.tenure_w,
        'license_w',  s.license_w
      ),
      'team_totals', jsonb_build_object(
        'wh_total',      ROUND(s.wh_total, 4),
        'team_avg_13wk', ROUND(s.team_avg_13wk, 2),
        'team_avg_4wk',  ROUND(s.team_avg_4wk, 2),
        'qtd_sp_total',  ROUND(s.qtd_sp_total, 2)
      ),
      'constants', jsonb_build_object(
        'burden_multiplier', v_burden_mult,
        'wc_annual',         v_wc_annual,
        'split_thirds',      true
      ),
      'pool_basis',       v_pool_result->'basis',
      'schedule',         v_pool_result->'schedule',
      'carveouts_detail', v_carveouts_result
    )
  FROM settled s
  ORDER BY s.last_name;
END;
$function$;

COMMENT ON FUNCTION public.compute_weekly_comp_v3(uuid, date) IS
  'Quarterly-input residual pool team comp with 1/3-1/3-1/3 split (retention weighted-hours + rolling-13wk SP avg + rolling-4wk SP avg). '
  'All subtractions QTD-elapsed in current cycle. Runs alongside v2 during rollout evaluation (v3 was built 2026-07-12).';
