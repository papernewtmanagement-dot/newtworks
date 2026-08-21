-- ═══════════════════════════════════════════════════════════════
-- 2026-07-11 — Structural changes per Peter directive:
-- (1) Sales/Retention 65/35 split happens BEFORE commissions deducted
--     Commissions come out of Sales Share only (retention unaffected)
-- (2) MVP prize cart formula = 1% × on-time Scorecard annual (drop wins ratio, drop SMVC)
-- Also: enrich diag output for expanded FormulaBreakdown
-- ═══════════════════════════════════════════════════════════════

-- Patch compute_pool_carveouts MVP formula
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
  v_max_possible_wins   int;

  v_annual_mvp          numeric := 0;
  v_annual_wtq          numeric := 0;
  v_wtq_halted          boolean := false;
  v_wtq_halt_reason     text := NULL;

  v_total_carveouts     numeric;
BEGIN
  v_pool_result         := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_annual_ot_smvc      := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_smvc_dollars','')::numeric, 0);
  v_annual_ot_scorecard := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_scorecard_dollars','')::numeric, 0);
  v_annual_ot_basis     := v_annual_ot_smvc + v_annual_ot_scorecard;

  -- MANAGER BONUS
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

  -- LIFE INSURANCE STIPEND
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

  -- APPAREL
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

  -- HEALTH DEVELOPMENT BONUS
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

  -- CHAMPIONS CIRCLE RESERVE (3% × OT basis, carve-and-forget)
  v_annual_cc := v_cc_pct * v_annual_ot_basis;

  -- Cycle bounds
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

  -- MVP PRIZE CART: 1% × on-time Scorecard annual (Peter directive 2026-07-11).
  -- Was: 1% × OT basis × prior_qtr_wins/13. Dropped SMVC + wins ratio.
  v_annual_mvp := 0.01 * v_annual_ot_scorecard;

  -- WtQ Trip stays 10% × (OT SMVC + OT Scorecard) × curr_qtr_wins/13 with 9-win floor
  v_max_possible_wins := v_curr_qtr_wins + GREATEST(0, 13 - v_week_of_cycle);
  IF v_max_possible_wins < 9 THEN
    v_annual_wtq      := 0;
    v_wtq_halted      := true;
    v_wtq_halt_reason := format(
      'wins_to_date (%s) + weeks_remaining (%s) = %s < 9 floor',
      v_curr_qtr_wins, GREATEST(0, 13 - v_week_of_cycle), v_max_possible_wins
    );
  ELSE
    v_annual_wtq := 0.10 * v_annual_ot_basis * (v_curr_qtr_wins::numeric / 13.0);
  END IF;

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
      'max_possible_wins_this_cycle', v_max_possible_wins,
      'prior_cycle_start',           v_prior_cycle_start,
      'prior_cycle_end',             v_prior_cycle_end,
      'prior_cycle_wins',            v_prior_qtr_wins
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
      'annual_dollars', ROUND(v_annual_mvp, 2),
      'weekly_dollars', ROUND(v_annual_mvp / 52.0, 2),
      'formula',        '1% × on-time Scorecard annual (Peter 2026-07-11)',
      'note',           'Funds quarterly prize-cart restock. Formula no longer scales by wins.'
    ),
    'wtq_trip', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_wtq, 2),
      'weekly_dollars', ROUND(v_annual_wtq / 52.0, 2),
      'formula',        '10% × on-time (SMVC + Scorecard) annual × current_qtr_wins/13',
      'floor_wins',     9,
      'halted',         v_wtq_halted,
      'halt_reason',    v_wtq_halt_reason,
      'note',           'Accrues weekly. Halts if math cannot reach 9-wins floor.'
    ),
    'total_annual_carveouts', ROUND(v_total_carveouts, 2),
    'total_weekly_carveouts', ROUND(v_total_carveouts / 52.0, 2),
    'computed_at', now()
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════
-- Restructure compute_weekly_comp_residual_pool: split BEFORE commission
-- Commission comes out of Sales Share only.
-- Enrich diag with envelope-derivation inputs + per-person base/commission detail.
-- ═══════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.compute_weekly_comp_residual_pool(uuid, date);

CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(
   team_member_id uuid, full_name text, role text, role_category text, role_level text,
   annual_base_salary numeric, weekly_base_salary numeric,
   annual_commission_projected numeric, weekly_commission_projected numeric,
   ytd_sales_points numeric, sales_points_share_pct numeric,
   weighted_hours_at_40 numeric, retention_hours_share_pct numeric,
   person_share_pct numeric,
   annual_bonus numeric, weekly_bonus numeric,
   weekly_sales_pool_share numeric, weekly_retention_pool_share numeric,
   annual_total_comp numeric, weekly_total_comp numeric,
   diagnostics jsonb
 )
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_year               int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_quarter            int := EXTRACT(QUARTER FROM p_week_end_date)::int;
  v_q_start            date := make_date(v_year, ((v_quarter - 1) * 3) + 1, 1);
  v_pool_result        jsonb;
  v_carveouts_result   jsonb;
  v_annual_envelope    numeric;
  v_annual_carveouts   numeric;
  v_burden_multiplier  CONSTANT numeric := 0.08;
  v_wc_annual          CONSTANT numeric := 500.00;
  v_sales_weight       CONSTANT numeric := 0.65;
  v_retention_weight   CONSTANT numeric := 0.35;
BEGIN
  v_pool_result      := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_carveouts_result := public.compute_pool_carveouts(p_agency_id, p_week_end_date);
  v_annual_envelope  := COALESCE(NULLIF(v_pool_result->'envelope'->>'annual_dollars','')::numeric, 0);
  v_annual_carveouts := COALESCE(NULLIF(v_carveouts_result->>'total_annual_carveouts','')::numeric, 0);

  RETURN QUERY
  WITH roster AS (
    SELECT et.team_id AS id, et.first_name, et.last_name, et.role, et.role_category, et.role_level,
           t.pay_type, t.pay_rate, t.work_location, et.start_date,
           t.license_pc, t.license_lh, t.license_ips,
           t.weekly_health_benefit_agency_paid
    FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
    JOIN public.team t ON t.id = et.team_id
  ),
  base_calc AS (
    SELECT r.*,
      CASE
        WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 52
        WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * 52
        ELSE 0
      END AS c_annual_base,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS c_base_tenure_mult
    FROM roster r
  ),
  quarter_bounds AS (
    SELECT q, make_date(v_year, ((q - 1) * 3) + 1, 1)::date AS q_start,
      (make_date(v_year, q * 3, 1) + INTERVAL '1 month - 1 day')::date AS q_end
    FROM generate_series(1, 4) AS q
  ),
  quarter_realized AS (
    SELECT ((period_month - 1) / 3) + 1 AS q, MAX(period_month) IS NOT NULL AS is_realized
    FROM public.producer_production
    WHERE agency_id = p_agency_id AND period_year = v_year
    GROUP BY ((period_month - 1) / 3) + 1
  ),
  q_sp AS (
    SELECT wctd.team_member_id AS tm_id, qb.q, MAX(COALESCE(wctd.sales_points, 0)) AS q_max_sp
    FROM base_calc b
    CROSS JOIN quarter_bounds qb
    LEFT JOIN public.weekly_cpr_reports wr
      ON wr.agency_id = p_agency_id AND wr.week_ending_date >= qb.q_start
     AND wr.week_ending_date <= qb.q_end AND wr.week_ending_date <= p_week_end_date
    LEFT JOIN public.weekly_cpr_team_detail wctd
      ON wctd.weekly_cpr_report_id = wr.id AND wctd.team_member_id = b.id
    GROUP BY wctd.team_member_id, qb.q
  ),
  sp_annotated AS (
    SELECT qs.tm_id, qs.q, qs.q_max_sp, COALESCE(qr.is_realized, false) AS is_realized
    FROM q_sp qs LEFT JOIN quarter_realized qr ON qr.q = qs.q
    WHERE qs.tm_id IS NOT NULL
  ),
  sp_projection AS (
    SELECT tm_id,
      SUM(CASE WHEN is_realized THEN q_max_sp ELSE 0 END) AS realized_sp_sum,
      COUNT(*) FILTER (WHERE is_realized) AS realized_count,
      COUNT(*) FILTER (WHERE NOT is_realized) AS unrealized_count,
      CASE WHEN COUNT(*) FILTER (WHERE is_realized) > 0
        THEN SUM(CASE WHEN is_realized THEN q_max_sp ELSE 0 END) / COUNT(*) FILTER (WHERE is_realized)
        ELSE 0 END AS avg_realized_sp
    FROM sp_annotated GROUP BY tm_id
  ),
  sp_annualized AS (
    SELECT sp.tm_id, sp.realized_sp_sum + (sp.avg_realized_sp * sp.unrealized_count) AS c_annual_sp,
      sp.realized_sp_sum, sp.avg_realized_sp, sp.realized_count, sp.unrealized_count
    FROM sp_projection sp
  ),
  curr_sp AS (
    SELECT b.id AS tm_id,
      COALESCE((
        SELECT wctd_c.sales_points
        FROM public.weekly_cpr_reports wr_c
        JOIN public.weekly_cpr_team_detail wctd_c ON wctd_c.weekly_cpr_report_id = wr_c.id
        WHERE wr_c.agency_id = p_agency_id
          AND wr_c.week_ending_date = p_week_end_date
          AND wctd_c.team_member_id = b.id
        LIMIT 1
      ), 0) AS qtd_sp
    FROM base_calc b
  ),
  prior_sp AS (
    SELECT b.id AS tm_id,
      COALESCE((
        SELECT wctd_p.sales_points
        FROM public.weekly_cpr_reports wr_p
        JOIN public.weekly_cpr_team_detail wctd_p ON wctd_p.weekly_cpr_report_id = wr_p.id
        WHERE wr_p.agency_id = p_agency_id
          AND wr_p.week_ending_date < p_week_end_date
          AND wr_p.week_ending_date >= v_q_start
          AND wctd_p.team_member_id = b.id
        ORDER BY wr_p.week_ending_date DESC
        LIMIT 1
      ), 0) AS prior_qtd_sp
    FROM base_calc b
  ),
  weekly_comm AS (
    SELECT cur.tm_id, GREATEST(0, cur.qtd_sp - prior.prior_qtd_sp) AS weekly_commission
    FROM curr_sp cur JOIN prior_sp prior ON prior.tm_id = cur.tm_id
  ),
  wh_calc AS (
    SELECT b.id AS tm_id, 40.0 AS hours,
      CASE WHEN b.role = 'Reception' THEN 1.00
           WHEN b.role IN ('Acquisition', 'Inside Sales') THEN 0.25 ELSE 0 END AS role_w,
      CASE WHEN b.work_location = 'in_office' THEN 1.00
           WHEN b.work_location = 'remote' THEN 0.50 ELSE 1.00 END AS location_w,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - b.start_date)::numeric / 7.0) / 52.0)) AS tenure_w,
      LEAST(1.00, 0.50
           + CASE WHEN b.license_pc  THEN 0.35 ELSE 0 END
           + CASE WHEN b.license_lh  THEN 0.10 ELSE 0 END
           + CASE WHEN b.license_ips THEN 0.05 ELSE 0 END) AS license_w
    FROM base_calc b
  ),
  wh_final AS (
    SELECT wh.tm_id, wh.hours * wh.role_w * wh.location_w * wh.tenure_w * wh.license_w AS weighted_hours,
      wh.role_w, wh.location_w, wh.tenure_w, wh.license_w
    FROM wh_calc wh
  ),
  combined AS (
    SELECT b.id AS tm_id, b.first_name, b.last_name, b.role, b.role_category, b.role_level,
      b.c_annual_base, b.c_base_tenure_mult, b.weekly_health_benefit_agency_paid, b.pay_type, b.pay_rate,
      (b.c_annual_base * b.c_base_tenure_mult) AS c_annual_base_in_envelope,
      (b.c_annual_base * (1 + v_burden_multiplier) * (1 - b.c_base_tenure_mult)) AS c_annual_growth_budget,
      COALESCE(spa.c_annual_sp, 0) AS c_annual_comm,
      COALESCE(spa.c_annual_sp, 0) AS c_annual_sp,
      COALESCE(wc.weekly_commission, 0) AS c_weekly_comm,
      COALESCE(cs.qtd_sp, 0) AS c_qtd_sp,
      COALESCE(wf.weighted_hours, 0) AS weighted_hours,
      spa.realized_sp_sum AS realized_comm_sum,
      spa.avg_realized_sp AS avg_realized_comm,
      spa.realized_count  AS comm_realized_q,
      spa.unrealized_count AS comm_unrealized_q,
      wf.role_w, wf.location_w, wf.tenure_w, wf.license_w
    FROM base_calc b
    LEFT JOIN sp_annualized spa ON spa.tm_id = b.id
    LEFT JOIN weekly_comm   wc  ON wc.tm_id  = b.id
    LEFT JOIN curr_sp       cs  ON cs.tm_id  = b.id
    LEFT JOIN wh_final      wf  ON wf.tm_id  = b.id
  ),
  team_totals AS (
    SELECT
      SUM(c_annual_base) AS total_base,
      SUM(c_annual_base_in_envelope) AS total_base_in_envelope,
      SUM(c_annual_growth_budget) AS total_growth_budget,
      SUM(c_annual_comm) AS total_comm,
      SUM(c_annual_sp)   AS total_sp,
      -- SALES-CATEGORY sales points only (for share calc inside Sales Share)
      SUM(CASE WHEN role_category = 'Sales' THEN c_annual_sp ELSE 0 END) AS total_sp_sales_only,
      SUM(weighted_hours) AS total_wh,
      SUM(COALESCE(weekly_health_benefit_agency_paid, 0) * 52) AS total_health_annual
    FROM combined
  ),
  bonus_pool_calc AS (
    SELECT
      tt.total_base, tt.total_base_in_envelope, tt.total_growth_budget,
      tt.total_comm, tt.total_sp, tt.total_sp_sales_only, tt.total_wh, tt.total_health_annual,
      v_annual_envelope AS envelope,
      v_annual_carveouts AS carveouts,
      v_wc_annual AS wc,
      -- STRUCTURAL CHANGE 2026-07-11: commissions removed from PRE-split math.
      -- gross_pool = (envelope - WC) / (1 + burden) - team_base_in_envelope - team_health_annual
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base_in_envelope - tt.total_health_annual
      ) AS annual_bonus_pool_gross,
      -- net_pool = gross_pool - carveouts (both eaten before split)
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base_in_envelope - tt.total_health_annual - v_annual_carveouts
      ) AS annual_bonus_pool
    FROM team_totals tt
  ),
  bonus_pool AS (
    SELECT bpc.*,
      -- Split first (65/35)
      bpc.annual_bonus_pool * v_sales_weight     AS annual_sales_pool_pre_comm,
      bpc.annual_bonus_pool * v_retention_weight AS annual_retention_pool,
      -- Commission comes out of Sales Share only
      GREATEST(0, bpc.annual_bonus_pool * v_sales_weight - bpc.total_comm) AS annual_sales_pool,
      (bpc.total_base_in_envelope + bpc.total_comm + bpc.annual_bonus_pool + bpc.carveouts) * v_burden_multiplier AS burden
    FROM bonus_pool_calc bpc
  ),
  distributed AS (
    SELECT c.*,
      bp.annual_bonus_pool, bp.annual_bonus_pool_gross, bp.carveouts, bp.total_health_annual,
      bp.annual_sales_pool, bp.annual_sales_pool_pre_comm, bp.annual_retention_pool,
      bp.total_sp AS bp_total_sp, bp.total_sp_sales_only AS bp_total_sp_sales_only,
      bp.total_wh AS bp_total_wh, bp.total_growth_budget AS bp_total_growth_budget,
      -- SP share within SALES CATEGORY (denominator = Sales-only total SP)
      CASE WHEN bp.total_sp_sales_only > 0 AND c.role_category = 'Sales'
           THEN c.c_annual_sp / bp.total_sp_sales_only
           ELSE 0 END AS sp_share,
      -- Weighted-hours share (all roles contribute; retention team weight is 0)
      CASE WHEN bp.total_wh > 0 THEN c.weighted_hours / bp.total_wh ELSE 0 END AS wh_share
    FROM combined c CROSS JOIN bonus_pool bp
  ),
  final AS (
    SELECT d.*,
      -- Sales portion: SP share × Sales pool (post-commission)
      d.sp_share * d.annual_sales_pool     AS annual_sales_share,
      -- Retention portion: WH share × Retention pool (independent of commissions)
      d.wh_share * d.annual_retention_pool AS annual_retention_share,
      (d.sp_share * d.annual_sales_pool + d.wh_share * d.annual_retention_pool) AS annual_bonus,
      -- Person share % is now less meaningful post-split; kept for backwards compat as
      -- (annual_bonus / net_bonus_pool) * 100
      CASE WHEN d.annual_bonus_pool > 0
           THEN (d.sp_share * d.annual_sales_pool + d.wh_share * d.annual_retention_pool) / d.annual_bonus_pool
           ELSE 0 END AS person_share
    FROM distributed d
  )
  SELECT
    f.tm_id,
    f.first_name || ' ' || f.last_name,
    f.role, f.role_category, f.role_level,
    ROUND(f.c_annual_base, 2), ROUND(f.c_annual_base / 52.0, 2),
    ROUND(f.c_annual_comm, 2),
    ROUND(f.c_weekly_comm, 2),
    ROUND(f.c_qtd_sp, 2),
    ROUND(f.sp_share * 100, 4),
    ROUND(f.weighted_hours, 4),
    ROUND(f.wh_share * 100, 4),
    ROUND(f.person_share * 100, 4),
    ROUND(f.annual_bonus, 2),
    ROUND(f.annual_bonus / 52.0, 2),
    ROUND(f.annual_sales_share / 52.0, 2),
    ROUND(f.annual_retention_share / 52.0, 2),
    ROUND(f.c_annual_base + f.c_annual_comm + f.annual_bonus, 2),
    ROUND((f.c_annual_base + f.c_annual_comm + f.annual_bonus) / 52.0, 2),
    jsonb_build_object(
      'realized_comm_sum',    f.realized_comm_sum,
      'avg_realized_comm',    f.avg_realized_comm,
      'comm_realized_q',      f.comm_realized_q,
      'comm_unrealized_q',    f.comm_unrealized_q,
      'weight_factors', jsonb_build_object(
        'hours_baseline', 40.0,
        'role_w', f.role_w, 'location_w', f.location_w,
        'tenure_w', f.tenure_w, 'license_w', f.license_w),
      'base_tenure_mult',     f.c_base_tenure_mult,
      'annual_base_in_envelope', ROUND(f.c_annual_base_in_envelope, 2),
      'annual_growth_budget', ROUND(f.c_annual_growth_budget, 2),
      'weekly_growth_budget', ROUND(f.c_annual_growth_budget / 52.0, 2),
      'annual_envelope',      v_annual_envelope,
      'annual_bonus_pool',    f.annual_bonus_pool,
      'annual_bonus_pool_gross', f.annual_bonus_pool_gross,
      'annual_sales_pool_pre_comm', f.annual_sales_pool_pre_comm,
      'annual_sales_pool',    f.annual_sales_pool,
      'annual_retention_pool', f.annual_retention_pool,
      'weekly_sales_pool',    ROUND(f.annual_sales_pool / 52.0, 2),
      'weekly_sales_pool_pre_comm', ROUND(f.annual_sales_pool_pre_comm / 52.0, 2),
      'weekly_retention_pool', ROUND(f.annual_retention_pool / 52.0, 2),
      'annual_carveouts',     f.carveouts,
      'team_total_base',      (SELECT total_base FROM team_totals),
      'team_total_base_in_envelope', (SELECT total_base_in_envelope FROM team_totals),
      'team_total_growth_budget',    (SELECT total_growth_budget FROM team_totals),
      'team_total_comm',      (SELECT total_comm FROM team_totals),
      'team_total_sp',        (SELECT total_sp FROM team_totals),
      'team_total_sp_sales_only', (SELECT total_sp_sales_only FROM team_totals),
      'team_total_health_annual', f.total_health_annual,
      'team_total_burden',    (SELECT burden FROM bonus_pool),
      'team_wc_annual',       v_wc_annual,
      'sales_weight',         v_sales_weight,
      'retention_weight',     v_retention_weight,
      'burden_multiplier',    v_burden_multiplier,
      'commission_semantic',  'sp_delta_this_week',
      'person_pay_type',      f.pay_type,
      'person_pay_rate',      f.pay_rate,
      'pool_basis',           v_pool_result->'basis',
      'schedule',             v_pool_result->'schedule',
      'envelope',             v_pool_result->'envelope',
      'carveouts_detail',     v_carveouts_result
    )
  FROM final f
  ORDER BY f.last_name;
END;
$function$;
