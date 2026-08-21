-- New residual pool math (Peter directives 2026-07-12 pm):
-- 1. Cycle boundaries from current_cycle_info (13 weeks, fixes weeks_in_quarter=12 calendar-Q bug)
-- 2. Manager Bonus + HDB + MVP Prize Cart + WtQ Trip subtract from envelope INSIDE (were outside)
-- 3. Commissions eat WHOLE POOL (were Sales share only, reverses 2026-07-11 lock)
-- 4. Split pool into 1/3-1/3-1/3: retention hours (this week), rolling-13wk SP avg, rolling-4wk SP avg
-- 5. NO SP role gate — anyone with SP participates (Cassie/Stephanie included)
-- Carveouts still outside pool: Apparel, Life Ins Stipend, Champions Circle Reserve
CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool(
  p_agency_id     uuid,
  p_week_end_date date
)
RETURNS TABLE (
  team_member_id                uuid,
  full_name                     text,
  role                          text,
  role_category                 text,
  role_level                    text,
  annual_base_salary            numeric,
  weekly_base_salary            numeric,
  annual_commission_projected   numeric,
  weekly_commission_projected   numeric,
  ytd_sales_points              numeric,
  sales_points_share_pct        numeric,   -- % of combined SP buckets (13wk+4wk)
  weighted_hours_at_40          numeric,
  retention_hours_share_pct     numeric,
  person_share_pct              numeric,
  annual_bonus                  numeric,
  weekly_bonus                  numeric,
  weekly_sales_pool_share       numeric,   -- combined this-week (SP-13wk + SP-4wk) settlement
  weekly_retention_pool_share   numeric,   -- this-week retention settlement
  annual_total_comp             numeric,
  weekly_total_comp             numeric,
  diagnostics                   jsonb
)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_cycle_start         date;
  v_cycle_end           date;
  v_week_of_cycle       int;
  v_weeks_in_cycle      int  := 13;
  v_year                int  := EXTRACT(YEAR    FROM p_week_end_date)::int;
  v_quarter             int  := EXTRACT(QUARTER FROM p_week_end_date)::int;
  v_pool_result         jsonb;
  v_carveouts_result    jsonb;
  v_annual_basis        numeric;
  v_current_pool_pct    numeric;
  v_qtd_envelope        numeric;
  v_cycle_envelope      numeric;
  v_weekly_envelope     numeric;
  v_burden_mult         CONSTANT numeric := 0.08;
  v_wc_annual           CONSTANT numeric := 500.00;
  v_qtd_wc              numeric;
  -- Weekly carveout dollars (from compute_pool_carveouts)
  v_weekly_apparel      numeric;
  v_weekly_life_ins     numeric;
  v_weekly_cc_reserve   numeric;
  v_weekly_prize_cart   numeric;
  v_weekly_wtq_trip     numeric;
  -- QTD accruals for outside-pool carveouts
  v_qtd_apparel         numeric;
  v_qtd_life_ins        numeric;
  v_qtd_cc_reserve      numeric;
BEGIN
  SELECT cycle_start, cycle_end, week_of_cycle
  INTO   v_cycle_start, v_cycle_end, v_week_of_cycle
  FROM   public.current_cycle_info(p_agency_id, p_week_end_date);

  IF v_cycle_start IS NULL THEN
    RETURN;
  END IF;

  v_pool_result      := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_carveouts_result := public.compute_pool_carveouts(p_agency_id, p_week_end_date);
  v_annual_basis     := COALESCE(NULLIF(v_pool_result->'basis'->>'total_basis_annual','')::numeric, 0);
  v_current_pool_pct := COALESCE(NULLIF(v_pool_result->'schedule'->>'pool_pct','')::numeric, 0);
  v_weekly_envelope  := (v_annual_basis * v_current_pool_pct / 100.0) / 52.0;

  -- QTD envelope: sum ramp-adjusted weekly envelopes for cycle weeks up to current
  SELECT COALESCE(SUM((v_annual_basis * pool_pct / 100.0) / 52.0), 0)
  INTO   v_qtd_envelope
  FROM   public.team_comp_pool_schedule
  WHERE  agency_id = p_agency_id
    AND  week_end_date >= v_cycle_start
    AND  week_end_date <= p_week_end_date;

  -- Full-cycle envelope for reference
  SELECT COALESCE(SUM((v_annual_basis * pool_pct / 100.0) / 52.0), 0)
  INTO   v_cycle_envelope
  FROM   public.team_comp_pool_schedule
  WHERE  agency_id = p_agency_id
    AND  week_end_date >= v_cycle_start
    AND  week_end_date <= v_cycle_end;

  v_weekly_apparel    := COALESCE(NULLIF(v_carveouts_result->'apparel'->>'weekly_dollars','')::numeric, 0);
  v_weekly_life_ins   := COALESCE(NULLIF(v_carveouts_result->'life_insurance_stipend'->>'weekly_dollars','')::numeric, 0);
  v_weekly_cc_reserve := COALESCE(NULLIF(v_carveouts_result->'champions_circle'->>'weekly_dollars','')::numeric, 0);
  v_weekly_prize_cart := COALESCE(NULLIF(v_carveouts_result->'mvp_prize_cart'->>'weekly_dollars','')::numeric, 0);
  v_weekly_wtq_trip   := COALESCE(NULLIF(v_carveouts_result->'wtq_trip'->>'weekly_dollars','')::numeric, 0);

  v_qtd_wc         := (v_wc_annual / 52.0) * v_week_of_cycle;
  v_qtd_apparel    := v_weekly_apparel    * v_week_of_cycle;
  v_qtd_life_ins   := v_weekly_life_ins   * v_week_of_cycle;
  v_qtd_cc_reserve := v_weekly_cc_reserve * v_week_of_cycle;

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
    SELECT week_end_date FROM public.team_comp_pool_schedule
    WHERE agency_id = p_agency_id
      AND week_end_date >= v_cycle_start
      AND week_end_date <= p_week_end_date
  ),
  -- Per-person, per-cycle-week base pay + that week's tenure_mult
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
      SUM(week_base_paid * week_tenure_mult) AS qtd_base_in_pool,
      SUM(week_base_paid * (1 - week_tenure_mult)) AS qtd_growth_budget
    FROM base_by_week
    GROUP BY tm_id
  ),
  cpr_actuals_qtd AS (
    -- Sum actual weekly figures already stored on prior wctd rows this cycle.
    -- Also grab current-week's QTD SP and commission for display.
    SELECT r.id AS tm_id,
      COALESCE(SUM(wctd.manager_bonus), 0) AS qtd_mgr_bonus,
      COALESCE(SUM(wctd.health_bonus), 0)  AS qtd_hdb,
      COALESCE(SUM(wctd.bonus), 0)         AS prior_qtd_bonus_paid,
      COALESCE(SUM(wctd.sales_pool_share), 0)     AS prior_qtd_sales_paid,
      COALESCE(SUM(wctd.retention_pool_share), 0) AS prior_qtd_retention_paid,
      COALESCE(SUM(wctd.commission), 0)    AS qtd_commission_from_col,
      MAX(CASE WHEN wr.week_ending_date = p_week_end_date THEN wctd.sales_points END) AS current_week_qtd_sp,
      MAX(CASE WHEN wr.week_ending_date = p_week_end_date THEN wctd.commission END)   AS current_week_comm
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
  -- Prize Cart + WtQ QTD accrual (weekly × weeks elapsed)
  prize_wtq_qtd AS (
    SELECT
      v_weekly_prize_cart * v_week_of_cycle AS qtd_prize_cart,
      v_weekly_wtq_trip   * v_week_of_cycle AS qtd_wtq_trip
  ),
  -- Rolling SP averages: 13 Saturdays ending p_week_end_date, using wctd.commission (weekly-earned SP $).
  -- Pre-hire weeks and NULLs = 0. Denominator always 13 or 4.
  weeks_series AS (
    SELECT (p_week_end_date - (n * 7))::date AS week_ending, n AS lookback_idx
    FROM generate_series(0, 12) n
  ),
  weekly_earned AS (
    SELECT r.id AS tm_id, ws.week_ending, ws.lookback_idx,
      CASE
        WHEN r.start_date IS NOT NULL AND ws.week_ending < r.start_date THEN 0
        ELSE COALESCE((
          SELECT wctd.commission
          FROM public.weekly_cpr_reports wr
          JOIN public.weekly_cpr_team_detail wctd ON wctd.weekly_cpr_report_id = wr.id
          WHERE wr.agency_id = p_agency_id
            AND wr.week_ending_date = ws.week_ending
            AND wctd.team_member_id = r.id
          LIMIT 1
        ), 0)
      END AS earned_sp
    FROM roster r CROSS JOIN weeks_series ws
  ),
  sp_rolling AS (
    SELECT tm_id,
      SUM(earned_sp) / 13.0 AS avg_13wk,
      SUM(CASE WHEN lookback_idx < 4 THEN earned_sp ELSE 0 END) / 4.0 AS avg_4wk
    FROM weekly_earned
    GROUP BY tm_id
  ),
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
      COALESCE(b.qtd_base_paid, 0)          AS c_qtd_base_paid,
      COALESCE(b.qtd_base_in_pool, 0)       AS c_qtd_base_in_pool,
      COALESCE(b.qtd_growth_budget, 0)      AS c_qtd_growth_budget,
      COALESCE(a.qtd_mgr_bonus, 0)          AS c_qtd_mgr,
      COALESCE(a.qtd_hdb, 0)                AS c_qtd_hdb,
      COALESCE(a.prior_qtd_bonus_paid, 0)   AS c_prior_qtd_bonus,
      COALESCE(a.prior_qtd_sales_paid, 0)   AS c_prior_qtd_sales,
      COALESCE(a.prior_qtd_retention_paid, 0) AS c_prior_qtd_retention,
      COALESCE(a.qtd_commission_from_col, 0) AS c_qtd_comm,
      COALESCE(a.current_week_qtd_sp, 0)    AS c_curr_qtd_sp,
      COALESCE(a.current_week_comm, 0)      AS c_curr_comm,
      COALESCE(sr.avg_13wk, 0)              AS c_avg_13wk,
      COALESCE(sr.avg_4wk, 0)               AS c_avg_4wk,
      COALESCE(wf.weighted_hours, 0)        AS c_weighted_hours,
      wf.role_w, wf.location_w, wf.tenure_w, wf.license_w
    FROM roster r
    LEFT JOIN base_qtd        b ON b.tm_id = r.id
    LEFT JOIN cpr_actuals_qtd a ON a.tm_id = r.id
    LEFT JOIN sp_rolling      sr ON sr.tm_id = r.id
    LEFT JOIN wh_final        wf ON wf.tm_id = r.id
  ),
  team_totals AS (
    SELECT
      SUM(c.c_qtd_base_paid)     AS qtd_base_paid_total,
      SUM(c.c_qtd_base_in_pool)  AS qtd_base_in_pool_total,
      SUM(c.c_qtd_growth_budget) AS qtd_growth_budget_total,
      SUM(c.c_qtd_mgr)           AS qtd_mgr_total,
      SUM(c.c_qtd_hdb)           AS qtd_hdb_total,
      SUM(c.c_qtd_comm)          AS qtd_comm_total,
      SUM(c.c_curr_qtd_sp)       AS qtd_sp_total,
      SUM(CASE WHEN c.r_role_category = 'Sales' THEN c.c_curr_qtd_sp ELSE 0 END) AS qtd_sp_sales_only,
      SUM(c.c_avg_13wk)          AS team_avg_13wk,
      SUM(c.c_avg_4wk)           AS team_avg_4wk,
      SUM(c.c_weighted_hours)    AS wh_total,
      SUM(COALESCE(c.weekly_health_benefit_agency_paid, 0)) AS team_weekly_health
    FROM combined c
  ),
  pool_calc AS (
    -- Bonus pool = (envelope − WC − health − mgr − hdb − prize_cart − wtq)/(1+burden) − base_in_pool − commission
    -- All 4 named carveouts INSIDE envelope (Peter 2026-07-12 pm).
    -- Commissions eat WHOLE POOL (Peter 2026-07-12 pm — reverses 2026-07-11 lock).
    SELECT tt.*, pwq.*,
      v_qtd_envelope AS qtd_envelope,
      v_qtd_wc       AS qtd_wc,
      tt.team_weekly_health * v_week_of_cycle AS qtd_health_total,
      GREATEST(0,
        (v_qtd_envelope - v_qtd_wc - (tt.team_weekly_health * v_week_of_cycle)
         - tt.qtd_mgr_total - tt.qtd_hdb_total
         - pwq.qtd_prize_cart - pwq.qtd_wtq_trip
        ) / (1.0 + v_burden_mult)
        - tt.qtd_base_in_pool_total
        - tt.qtd_comm_total
      ) AS qtd_bonus_pool
    FROM team_totals tt CROSS JOIN prize_wtq_qtd pwq
  ),
  pool_split AS (
    SELECT pc.*,
      pc.qtd_bonus_pool / 3.0 AS qtd_retention_pool,
      pc.qtd_bonus_pool / 3.0 AS qtd_sp_13wk_pool,
      pc.qtd_bonus_pool / 3.0 AS qtd_sp_4wk_pool
    FROM pool_calc pc
  ),
  distributed AS (
    SELECT c.*, ps.*,
      CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END AS ret_share_ratio,
      CASE WHEN ps.team_avg_13wk > 0 THEN c.c_avg_13wk / ps.team_avg_13wk ELSE 0 END AS sp13_share_ratio,
      CASE WHEN ps.team_avg_4wk > 0  THEN c.c_avg_4wk  / ps.team_avg_4wk  ELSE 0 END AS sp4_share_ratio
    FROM combined c CROSS JOIN pool_split ps
  ),
  earned AS (
    SELECT d.*,
      d.ret_share_ratio  * d.qtd_retention_pool AS qtd_ret_earned,
      d.sp13_share_ratio * d.qtd_sp_13wk_pool   AS qtd_sp13_earned,
      d.sp4_share_ratio  * d.qtd_sp_4wk_pool    AS qtd_sp4_earned,
      (d.ret_share_ratio * d.qtd_retention_pool
       + d.sp13_share_ratio * d.qtd_sp_13wk_pool
       + d.sp4_share_ratio  * d.qtd_sp_4wk_pool) AS qtd_bonus_earned,
      -- Combined SP share for the 2-column output layout:
      (d.sp13_share_ratio * d.qtd_sp_13wk_pool + d.sp4_share_ratio * d.qtd_sp_4wk_pool) AS qtd_sales_share,
      (d.ret_share_ratio * d.qtd_retention_pool) AS qtd_retention_share
    FROM distributed d
  ),
  settled AS (
    SELECT e.*,
      GREATEST(0, e.qtd_bonus_earned    - e.c_prior_qtd_bonus)     AS this_week_bonus,
      GREATEST(0, e.qtd_sales_share     - e.c_prior_qtd_sales)     AS this_week_sales_share,
      GREATEST(0, e.qtd_retention_share - e.c_prior_qtd_retention) AS this_week_retention_share
    FROM earned e
  ),
  weekly_pool_totals AS (
    SELECT
      SUM(this_week_sales_share)     AS weekly_sales_pool_sum,
      SUM(this_week_retention_share) AS weekly_retention_pool_sum,
      SUM(this_week_bonus)           AS weekly_bonus_pool_sum
    FROM settled
  )
  SELECT
    s.tm_id,
    (s.first_name || ' ' || s.last_name)::text,
    s.r_role::text, s.r_role_category::text, s.r_role_level::text,
    ROUND(CASE
      WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 52
      WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40 * 52
      ELSE 0
    END, 2) AS annual_base_salary,
    ROUND(CASE
      WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate
      WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40
      ELSE 0
    END, 2) AS weekly_base_salary,
    ROUND(s.c_curr_qtd_sp * 4, 2)                AS annual_commission_projected,
    ROUND(s.c_curr_comm, 2)                      AS weekly_commission_projected,
    ROUND(s.c_curr_qtd_sp, 2)                    AS ytd_sales_points,
    ROUND(CASE WHEN (s.team_avg_13wk + s.team_avg_4wk) > 0
                THEN (s.c_avg_13wk + s.c_avg_4wk) / (s.team_avg_13wk + s.team_avg_4wk)
                ELSE 0 END * 100, 4)             AS sales_points_share_pct,
    ROUND(s.c_weighted_hours, 4)                 AS weighted_hours_at_40,
    ROUND(s.ret_share_ratio * 100, 4)            AS retention_hours_share_pct,
    ROUND(CASE WHEN s.qtd_bonus_pool > 0
                THEN s.qtd_bonus_earned / s.qtd_bonus_pool
                ELSE 0 END * 100, 4)             AS person_share_pct,
    ROUND(s.qtd_bonus_earned * 4, 2)             AS annual_bonus,
    ROUND(s.this_week_bonus, 2)                  AS weekly_bonus,
    ROUND(s.this_week_sales_share, 2)            AS weekly_sales_pool_share,
    ROUND(s.this_week_retention_share, 2)        AS weekly_retention_pool_share,
    ROUND(
      CASE
        WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 52
        WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40 * 52
        ELSE 0
      END + s.c_curr_qtd_sp * 4 + s.qtd_bonus_earned * 4
    , 2) AS annual_total_comp,
    ROUND(
      CASE
        WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate
        WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40
        ELSE 0
      END + s.c_curr_comm + s.this_week_bonus
    , 2) AS weekly_total_comp,
    jsonb_build_object(
      'commission_semantic', 'wctd.commission column = weekly-earned SP $ (1 SP = $1)',
      'design_note',
        'Cycle envelope from current_cycle_info (13-week cycle). '
        || 'Manager Bonus, HDB, MVP Prize Cart, WtQ Trip subtract INSIDE envelope. '
        || 'Commissions eat WHOLE POOL (not sales share only). '
        || 'Pool splits 1/3-1/3-1/3: retention hours (this week), rolling 13-wk SP avg, rolling 4-wk SP avg. '
        || 'No SP role gate — anyone with SP earns share.',
      'person_pay_type', s.pay_type,
      'person_pay_rate', s.pay_rate,
      'weight_factors', jsonb_build_object(
        'hours_baseline', 40.0,
        'role_w',     s.role_w,
        'location_w', s.location_w,
        'tenure_w',   s.tenure_w,
        'license_w',  s.license_w
      ),
      'quarter', jsonb_build_object(
        'year',              v_year,
        'quarter',           v_quarter,
        'calendar_q_start',  (SELECT cq FROM (SELECT make_date(v_year, ((v_quarter - 1) * 3) + 1, 1) AS cq) sub),
        'calendar_q_end',    (SELECT ce FROM (SELECT (make_date(v_year, v_quarter * 3, 1) + INTERVAL '1 month - 1 day')::date AS ce) sub),
        'pool_start',        v_cycle_start,
        'pool_end',          v_cycle_end,
        'weeks_elapsed_qtd', v_week_of_cycle,
        'weeks_in_quarter',  v_weeks_in_cycle
      ),
      'envelope', jsonb_build_object(
        'annual_basis',        ROUND(v_annual_basis, 2),
        'current_pool_pct',    v_current_pool_pct,
        'weekly_envelope',     ROUND(v_weekly_envelope, 2),
        'qtd_envelope',        ROUND(s.qtd_envelope, 2),
        'quarterly_envelope',  ROUND(v_cycle_envelope, 2)
      ),
      'qtd_subtractions', jsonb_build_object(
        'qtd_wc',                        ROUND(s.qtd_wc, 2),
        'qtd_actual_health',             ROUND(s.qtd_health_total, 2),
        'qtd_manager_bonus_actual',      ROUND(s.qtd_mgr_total, 2),
        'qtd_hdb_actual',                ROUND(s.qtd_hdb_total, 2),
        'qtd_prize_cart_accrual',        ROUND(s.qtd_prize_cart, 2),
        'qtd_wtq_trip_accrual',          ROUND(s.qtd_wtq_trip, 2),
        'qtd_base_in_pool',              ROUND(s.qtd_base_in_pool_total, 2),
        'qtd_actual_base_paid',          ROUND(s.qtd_base_paid_total, 2),
        'qtd_growth_budget',             ROUND(s.qtd_growth_budget_total, 2),
        'qtd_growth_budget_note',        'paid × (1 - tenure_mult); agency-funded OUTSIDE pool',
        'qtd_actual_commission',         ROUND(s.qtd_comm_total, 2),
        'qtd_actual_commission_source',  'wctd.commission SUM (weekly-earned SP $); eats WHOLE pool',
        'qtd_burden',                    ROUND(
                                          (s.qtd_base_in_pool_total + s.qtd_comm_total + s.qtd_bonus_pool) * v_burden_mult
                                         , 2)
      ),
      'qtd_pools', jsonb_build_object(
        'qtd_bonus_pool',      ROUND(s.qtd_bonus_pool, 2),
        'qtd_retention_pool',  ROUND(s.qtd_retention_pool, 2),
        'qtd_sp_13wk_pool',    ROUND(s.qtd_sp_13wk_pool, 2),
        'qtd_sp_4wk_pool',     ROUND(s.qtd_sp_4wk_pool, 2),
        'split_thirds',        true
      ),
      'weekly_settlement', jsonb_build_object(
        'weekly_sales_pool',     ROUND((SELECT weekly_sales_pool_sum     FROM weekly_pool_totals), 2),
        'weekly_retention_pool', ROUND((SELECT weekly_retention_pool_sum FROM weekly_pool_totals), 2),
        'weekly_bonus_pool',     ROUND((SELECT weekly_bonus_pool_sum     FROM weekly_pool_totals), 2)
      ),
      'weekly_sales_pool',     ROUND((SELECT weekly_sales_pool_sum     FROM weekly_pool_totals), 2),
      'weekly_retention_pool', ROUND((SELECT weekly_retention_pool_sum FROM weekly_pool_totals), 2),
      'carveouts_outside_pool', jsonb_build_object(
        'annual_dollars',    ROUND((v_weekly_apparel + v_weekly_life_ins + v_weekly_cc_reserve) * 52, 2),
        'quarterly_dollars', ROUND((v_weekly_apparel + v_weekly_life_ins + v_weekly_cc_reserve) * 13, 2),
        'weekly_dollars',    ROUND(v_weekly_apparel + v_weekly_life_ins + v_weekly_cc_reserve, 2),
        'qtd_dollars',       ROUND(v_qtd_apparel + v_qtd_life_ins + v_qtd_cc_reserve, 2),
        'note',              'Agency-funded team benefits sitting outside the residual pool.',
        'items',             jsonb_build_object(
          'apparel_weekly',                v_weekly_apparel,
          'life_insurance_stipend_weekly', v_weekly_life_ins,
          'champions_circle_reserve_weekly', v_weekly_cc_reserve
        )
      ),
      'team_totals', jsonb_build_object(
        'qtd_actual_base_paid',   ROUND(s.qtd_base_paid_total, 2),
        'qtd_base_in_pool',       ROUND(s.qtd_base_in_pool_total, 2),
        'qtd_growth_budget',      ROUND(s.qtd_growth_budget_total, 2),
        'qtd_actual_health',      ROUND(s.qtd_health_total, 2),
        'qtd_actual_commission',  ROUND(s.qtd_comm_total, 2),
        'qtd_manager_bonus',      ROUND(s.qtd_mgr_total, 2),
        'qtd_hdb',                ROUND(s.qtd_hdb_total, 2),
        'qtd_sp_total',           ROUND(s.qtd_sp_total, 2),
        'qtd_sp_sales_only',      ROUND(s.qtd_sp_sales_only, 2),
        'team_avg_13wk',          ROUND(s.team_avg_13wk, 2),
        'team_avg_4wk',           ROUND(s.team_avg_4wk, 2),
        'wh_total',               ROUND(s.wh_total, 4)
      ),
      'person_qtd', jsonb_build_object(
        'qtd_actual_base_paid',            ROUND(s.c_qtd_base_paid, 2),
        'qtd_base_in_pool',                ROUND(s.c_qtd_base_in_pool, 2),
        'qtd_growth_budget',               ROUND(s.c_qtd_growth_budget, 2),
        'qtd_manager_bonus',               ROUND(s.c_qtd_mgr, 2),
        'qtd_hdb',                         ROUND(s.c_qtd_hdb, 2),
        'qtd_commission',                  ROUND(s.c_qtd_comm, 2),
        'qtd_sp',                          ROUND(s.c_curr_qtd_sp, 2),
        'rolling_13wk_avg_sp',             ROUND(s.c_avg_13wk, 2),
        'rolling_4wk_avg_sp',              ROUND(s.c_avg_4wk, 2),
        'qtd_ret_earned',                  ROUND(s.qtd_ret_earned, 2),
        'qtd_sp13_earned',                 ROUND(s.qtd_sp13_earned, 2),
        'qtd_sp4_earned',                  ROUND(s.qtd_sp4_earned, 2),
        'qtd_sales_share',                 ROUND(s.qtd_sales_share, 2),
        'qtd_retention_share',             ROUND(s.qtd_retention_share, 2),
        'qtd_bonus_earned',                ROUND(s.qtd_bonus_earned, 2),
        'prior_qtd_bonus_paid',            ROUND(s.c_prior_qtd_bonus, 2),
        'prior_qtd_sales_paid',            ROUND(s.c_prior_qtd_sales, 2),
        'prior_qtd_retention_paid',        ROUND(s.c_prior_qtd_retention, 2),
        'this_week_bonus_settlement',      ROUND(s.this_week_bonus, 2),
        'this_week_sales_settlement',      ROUND(s.this_week_sales_share, 2),
        'this_week_retention_settlement',  ROUND(s.this_week_retention_share, 2),
        'ret_share_ratio_pct',             ROUND(s.ret_share_ratio * 100, 4),
        'sp13_share_ratio_pct',            ROUND(s.sp13_share_ratio * 100, 4),
        'sp4_share_ratio_pct',             ROUND(s.sp4_share_ratio * 100, 4)
      ),
      'constants', jsonb_build_object(
        'sales_weight',      0.6667,
        'retention_weight',  0.3333,
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
