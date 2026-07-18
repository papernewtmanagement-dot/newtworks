-- Step 1 of HireGauge 7-role expansion sprint: rename team.role values
-- Acquisition → Outbound, Inside Sales → Inbound
-- Adds In-Book (Sales) and Support (Retention) to the CHECK enum (no data yet)
-- Behavior preserved: In-Book and Support fall through existing ELSE branches
-- in compute_weekly_comp_residual_pool, compute_weekly_pay, time_off_check_coverage,
-- and v_producer_roi_inputs. Wiring proper weights for the new roles is a later step.

BEGIN;

-- 1. Drop old CHECK
ALTER TABLE public.team DROP CONSTRAINT team_role_check;

-- 2. Rename existing data
UPDATE public.team SET role = 'Outbound' WHERE role = 'Acquisition';
UPDATE public.team SET role = 'Inbound'  WHERE role = 'Inside Sales';

-- 3. Add new CHECK with 6-value enum + NULL
ALTER TABLE public.team ADD CONSTRAINT team_role_check
  CHECK (role IS NULL OR role IN ('Outbound', 'Inbound', 'In-Book', 'Reception', 'Escalation', 'Support'));

-- 4. Rewrite the 3 SQL functions with strings swapped (behavior-equivalent rename only)

CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(team_member_id uuid, full_name text, role text, role_category text, role_level text, annual_base_salary numeric, weekly_base_salary numeric, annual_commission_projected numeric, weekly_commission_projected numeric, ytd_sales_points numeric, sales_points_share_pct numeric, weighted_hours_at_40 numeric, retention_hours_share_pct numeric, person_share_pct numeric, annual_bonus numeric, weekly_bonus numeric, weekly_sales_pool_share numeric, weekly_retention_pool_share numeric, annual_total_comp numeric, weekly_total_comp numeric, diagnostics jsonb)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_cycle_start date; v_cycle_end date; v_week_of_cycle int; v_weeks_in_cycle int := 13;
  v_year int := EXTRACT(YEAR FROM p_week_end_date)::int; v_quarter int := EXTRACT(QUARTER FROM p_week_end_date)::int;
  v_pool_result jsonb; v_carveouts_result jsonb;
  v_annual_basis numeric; v_current_pool_pct numeric; v_qtd_envelope numeric; v_cycle_envelope numeric; v_weekly_envelope numeric;
  v_burden_mult CONSTANT numeric := 0.08; v_wc_annual CONSTANT numeric := 500.00;
  v_qtd_wc numeric; v_weekly_apparel numeric; v_weekly_life_ins numeric; v_weekly_cc_reserve numeric;
  v_weekly_prize_cart numeric; v_weekly_wtq_trip numeric;
  v_weekly_hdb numeric; v_qtd_hdb_max numeric;
  v_qtd_apparel numeric; v_qtd_life_ins numeric; v_qtd_cc_reserve numeric;
  v_weekly_wtw_bonus numeric; v_weekly_gain_bonus numeric; v_weekly_leaderboard_bonus numeric; v_weekly_all_star_bonus numeric; v_weekly_trailblazer_bonus numeric; v_weekly_goals_total numeric;
BEGIN
  SELECT cycle_start, cycle_end, week_of_cycle INTO v_cycle_start, v_cycle_end, v_week_of_cycle FROM public.current_cycle_info(p_agency_id, p_week_end_date);
  IF v_cycle_start IS NULL THEN RETURN; END IF;
  v_pool_result := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_carveouts_result := public.compute_pool_carveouts(p_agency_id, p_week_end_date);
  v_annual_basis := COALESCE(NULLIF(v_pool_result->'basis'->>'total_basis_annual','')::numeric, 0);
  v_current_pool_pct := COALESCE(NULLIF(v_pool_result->'schedule'->>'pool_pct','')::numeric, 0);
  v_weekly_envelope := (v_annual_basis * v_current_pool_pct / 100.0) / 52.0;
  SELECT COALESCE(SUM((v_annual_basis * pool_pct / 100.0) / 52.0), 0) INTO v_qtd_envelope FROM public.team_comp_pool_schedule WHERE agency_id = p_agency_id AND week_end_date >= v_cycle_start AND week_end_date <= p_week_end_date;
  SELECT COALESCE(SUM((v_annual_basis * pool_pct / 100.0) / 52.0), 0) INTO v_cycle_envelope FROM public.team_comp_pool_schedule WHERE agency_id = p_agency_id AND week_end_date >= v_cycle_start AND week_end_date <= v_cycle_end;
  v_weekly_apparel := COALESCE(NULLIF(v_carveouts_result->'apparel'->>'weekly_dollars','')::numeric, 0);
  v_weekly_life_ins := COALESCE(NULLIF(v_carveouts_result->'life_insurance_stipend'->>'weekly_dollars','')::numeric, 0);
  v_weekly_cc_reserve := COALESCE(NULLIF(v_carveouts_result->'champions_circle'->>'weekly_dollars','')::numeric, 0);
  v_weekly_prize_cart := COALESCE(NULLIF(v_carveouts_result->'mvp_prize_cart'->>'weekly_dollars','')::numeric, 0);
  v_weekly_wtq_trip := COALESCE(NULLIF(v_carveouts_result->'wtq_trip'->>'weekly_dollars','')::numeric, 0);
  v_weekly_hdb := COALESCE(NULLIF(v_carveouts_result->'health_development_bonus'->>'weekly_dollars','')::numeric, 0);
  v_qtd_hdb_max := v_weekly_hdb * v_week_of_cycle;
  v_weekly_wtw_bonus := COALESCE(NULLIF(v_carveouts_result->'wtw_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_gain_bonus := COALESCE(NULLIF(v_carveouts_result->'gain_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_leaderboard_bonus := COALESCE(NULLIF(v_carveouts_result->'leaderboard_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_all_star_bonus := COALESCE(NULLIF(v_carveouts_result->'all_star_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_trailblazer_bonus := COALESCE(NULLIF(v_carveouts_result->'trailblazer_bonus'->>'weekly_dollars','')::numeric, 0);
  v_weekly_goals_total := v_weekly_wtw_bonus + v_weekly_gain_bonus + v_weekly_leaderboard_bonus + v_weekly_all_star_bonus + v_weekly_trailblazer_bonus;
  v_qtd_wc := (v_wc_annual / 52.0) * v_week_of_cycle;
  v_qtd_apparel := v_weekly_apparel * v_week_of_cycle; v_qtd_life_ins := v_weekly_life_ins * v_week_of_cycle; v_qtd_cc_reserve := v_weekly_cc_reserve * v_week_of_cycle;
  RETURN QUERY
  WITH roster AS (SELECT et.team_id AS id, et.first_name, et.last_name, et.role AS r_role, et.role_category AS r_role_category, et.role_level AS r_role_level, COALESCE(dsnap.pay_type, t.pay_type) AS pay_type, COALESCE(dsnap.pay_rate, t.pay_rate) AS pay_rate, COALESCE(dsnap.work_location, t.work_location) AS work_location, et.start_date, COALESCE(dsnap.license_pc, t.license_pc) AS license_pc, COALESCE(dsnap.license_lh, t.license_lh) AS license_lh, COALESCE(dsnap.license_ips, t.license_ips) AS license_ips, COALESCE(dsnap.weekly_health_benefit_agency_paid, t.weekly_health_benefit_agency_paid) AS weekly_health_benefit_agency_paid FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et JOIN public.team t ON t.id = et.team_id LEFT JOIN public.weekly_cpr_reports rr ON rr.agency_id = p_agency_id AND rr.week_ending_date = p_week_end_date LEFT JOIN public.weekly_cpr_team_detail dsnap ON dsnap.weekly_cpr_report_id = rr.id AND dsnap.team_member_id = et.team_id),
  cycle_weeks AS (SELECT week_end_date FROM public.team_comp_pool_schedule WHERE agency_id = p_agency_id AND week_end_date >= v_cycle_start AND week_end_date <= p_week_end_date),
  per_week_pay AS (SELECT r.id AS tm_id, cw.week_end_date, COALESCE(dh.pay_type, r.pay_type) AS wk_pay_type, COALESCE(dh.pay_rate, r.pay_rate) AS wk_pay_rate FROM roster r CROSS JOIN cycle_weeks cw LEFT JOIN public.weekly_cpr_reports rh ON rh.agency_id = p_agency_id AND rh.week_ending_date = cw.week_end_date LEFT JOIN public.weekly_cpr_team_detail dh ON dh.weekly_cpr_report_id = rh.id AND dh.team_member_id = r.id),
  base_by_week AS (SELECT r.id AS tm_id, cw.week_end_date, COALESCE((SELECT COALESCE((pd.raw_earnings->'items'->'SALARY'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'REGULAR'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'HOURLY'->>'period')::numeric, 0) FROM public.payroll_detail pd JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id WHERE pd.agency_id = p_agency_id AND pd.team_member_id = r.id AND pr.pay_period_end = cw.week_end_date LIMIT 1), CASE WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN (SELECT ROUND(SUM(daily_hrs) * pwp.wk_pay_rate, 2) FROM (SELECT ROUND(SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)::numeric, 2) AS daily_hrs FROM public.time_clock_entries tce WHERE tce.agency_id = p_agency_id AND tce.team_member_id = r.id AND tce.clock_out_at IS NOT NULL AND tce.clock_in_at::date >= (cw.week_end_date - 6) AND tce.clock_in_at::date <= cw.week_end_date GROUP BY DATE(tce.clock_in_at AT TIME ZONE 'America/Chicago')) daily) ELSE NULL END, CASE WHEN pwp.wk_pay_type = 'SALARY' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate WHEN pwp.wk_pay_type = 'HOURLY' AND pwp.wk_pay_rate IS NOT NULL THEN pwp.wk_pay_rate * 40 ELSE 0 END) AS week_base_paid, LEAST(1.00, GREATEST(0, FLOOR((cw.week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS week_tenure_mult FROM roster r CROSS JOIN cycle_weeks cw JOIN per_week_pay pwp ON pwp.tm_id = r.id AND pwp.week_end_date = cw.week_end_date),
  base_qtd AS (SELECT tm_id, SUM(week_base_paid) AS qtd_base_paid, SUM(week_base_paid * week_tenure_mult) AS qtd_base_in_pool, SUM(week_base_paid * (1 - week_tenure_mult)) AS qtd_growth_budget FROM base_by_week GROUP BY tm_id),
  actual_base_this_week AS (SELECT r.id AS tm_id, COALESCE((SELECT COALESCE((pd.raw_earnings->'items'->'SALARY'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'REGULAR'->>'period')::numeric, 0) + COALESCE((pd.raw_earnings->'items'->'HOURLY'->>'period')::numeric, 0) FROM public.payroll_detail pd JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id WHERE pd.agency_id = p_agency_id AND pd.team_member_id = r.id AND pr.pay_period_end = p_week_end_date LIMIT 1), CASE WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN (SELECT ROUND(SUM(daily_hrs) * r.pay_rate, 2) FROM (SELECT ROUND(SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)::numeric, 2) AS daily_hrs FROM public.time_clock_entries tce WHERE tce.agency_id = p_agency_id AND tce.team_member_id = r.id AND tce.clock_out_at IS NOT NULL AND tce.clock_in_at::date >= (p_week_end_date - 6) AND tce.clock_in_at::date <= p_week_end_date GROUP BY DATE(tce.clock_in_at AT TIME ZONE 'America/Chicago')) daily) ELSE NULL END, CASE WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 ELSE 0 END) AS actual_base_paid FROM roster r),
  actuals_through_current AS (SELECT r.id AS tm_id, COALESCE(SUM(wctd.manager_bonus), 0) AS qtd_mgr_bonus, COALESCE(SUM(wctd.health_bonus), 0) AS qtd_hdb, COALESCE(SUM(wctd.commission), 0) AS qtd_commission, MAX(CASE WHEN wr.week_ending_date = p_week_end_date THEN wctd.sales_points END) AS current_week_qtd_sp, MAX(CASE WHEN wr.week_ending_date = p_week_end_date THEN wctd.commission END) AS current_week_comm FROM roster r LEFT JOIN public.weekly_cpr_reports wr ON wr.agency_id = p_agency_id AND wr.week_ending_date >= v_cycle_start AND wr.week_ending_date <= p_week_end_date LEFT JOIN public.weekly_cpr_team_detail wctd ON wctd.weekly_cpr_report_id = wr.id AND wctd.team_member_id = r.id GROUP BY r.id),
  prior_paid AS (SELECT r.id AS tm_id, COALESCE(SUM(wctd.bonus), 0) AS prior_qtd_bonus_paid, COALESCE(SUM(wctd.sales_pool_share), 0) AS prior_qtd_sales_paid, COALESCE(SUM(wctd.retention_pool_share), 0) AS prior_qtd_retention_paid FROM roster r LEFT JOIN public.weekly_cpr_reports wr ON wr.agency_id = p_agency_id AND wr.week_ending_date >= v_cycle_start AND wr.week_ending_date < p_week_end_date LEFT JOIN public.weekly_cpr_team_detail wctd ON wctd.weekly_cpr_report_id = wr.id AND wctd.team_member_id = r.id GROUP BY r.id),
  prize_wtq_qtd AS (SELECT v_weekly_prize_cart * v_week_of_cycle AS qtd_prize_cart, v_weekly_wtq_trip * v_week_of_cycle AS qtd_wtq_trip, v_weekly_goals_total * v_week_of_cycle AS qtd_goals_total, v_weekly_wtw_bonus * v_week_of_cycle AS qtd_wtw_bonus, v_weekly_gain_bonus * v_week_of_cycle AS qtd_gain_bonus, v_weekly_leaderboard_bonus * v_week_of_cycle AS qtd_leaderboard_bonus, v_weekly_all_star_bonus * v_week_of_cycle AS qtd_all_star_bonus, v_weekly_trailblazer_bonus * v_week_of_cycle AS qtd_trailblazer_bonus),
  weeks_series AS (SELECT (p_week_end_date - (n * 7))::date AS week_ending, n AS lookback_idx FROM generate_series(0, 12) n),
  last_completed_q_per_person AS (SELECT DISTINCT ON (d.team_member_id) d.team_member_id, d.sales_points AS q_total, r.week_ending_date AS q_end_sat FROM public.weekly_cpr_team_detail d JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id WHERE r.agency_id = p_agency_id AND d.sales_points IS NOT NULL AND date_trunc('quarter', r.week_ending_date::timestamp)::date < date_trunc('quarter', p_week_end_date::timestamp)::date ORDER BY d.team_member_id, r.week_ending_date DESC),
  weekly_earned AS (SELECT r.id AS tm_id, ws.week_ending, ws.lookback_idx, CASE WHEN r.start_date IS NOT NULL AND ws.week_ending < r.start_date THEN 0 WHEN ws.week_ending >= v_cycle_start THEN COALESCE((SELECT wctd.commission FROM public.weekly_cpr_reports wr JOIN public.weekly_cpr_team_detail wctd ON wctd.weekly_cpr_report_id = wr.id WHERE wr.agency_id = p_agency_id AND wr.week_ending_date = ws.week_ending AND wctd.team_member_id = r.id LIMIT 1), 0) ELSE COALESCE((SELECT q_total / 13.0 FROM last_completed_q_per_person lcq WHERE lcq.team_member_id = r.id), 0) END AS earned_sp FROM roster r CROSS JOIN weeks_series ws),
  sp_rolling AS (SELECT tm_id, SUM(earned_sp) / 13.0 AS avg_13wk, SUM(CASE WHEN lookback_idx < 4 THEN earned_sp ELSE 0 END) / 4.0 AS avg_4wk FROM weekly_earned GROUP BY tm_id),
  wh_calc AS (SELECT r.id AS tm_id, 40.0 AS baseline_hours, CASE WHEN r.r_role = 'Reception' THEN 1.00 WHEN r.r_role IN ('Outbound', 'Inbound') THEN 0.25 ELSE 0 END AS role_w, CASE WHEN r.work_location = 'in_office' THEN 1.00 WHEN r.work_location = 'remote' THEN 0.50 ELSE 1.00 END AS location_w, LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS tenure_w, LEAST(1.00, 0.50 + CASE WHEN r.license_pc THEN 0.35 ELSE 0 END + CASE WHEN r.license_lh THEN 0.10 ELSE 0 END + CASE WHEN r.license_ips THEN 0.05 ELSE 0 END) AS license_w FROM roster r),
  wh_final AS (SELECT tm_id, baseline_hours * role_w * location_w * tenure_w * license_w AS weighted_hours, role_w, location_w, tenure_w, license_w FROM wh_calc),
  combined AS (SELECT r.id AS tm_id, r.first_name, r.last_name, r.r_role, r.r_role_category, r.r_role_level, r.pay_type, r.pay_rate, r.weekly_health_benefit_agency_paid, COALESCE(b.qtd_base_paid, 0) AS c_qtd_base_paid, COALESCE(b.qtd_base_in_pool, 0) AS c_qtd_base_in_pool, COALESCE(b.qtd_growth_budget, 0) AS c_qtd_growth_budget, COALESCE(abt.actual_base_paid, 0) AS c_actual_base_this_week, COALESCE(a.qtd_mgr_bonus, 0) AS c_qtd_mgr, COALESCE(a.qtd_hdb, 0) AS c_qtd_hdb, COALESCE(a.qtd_commission, 0) AS c_qtd_comm, COALESCE(a.current_week_qtd_sp, 0) AS c_curr_qtd_sp, COALESCE(a.current_week_comm, 0) AS c_curr_comm, COALESCE(pp.prior_qtd_bonus_paid, 0) AS c_prior_qtd_bonus, COALESCE(pp.prior_qtd_sales_paid, 0) AS c_prior_qtd_sales, COALESCE(pp.prior_qtd_retention_paid,0) AS c_prior_qtd_retention, COALESCE(sr.avg_13wk, 0) AS c_avg_13wk, COALESCE(sr.avg_4wk, 0) AS c_avg_4wk, COALESCE(wf.weighted_hours, 0) AS c_weighted_hours, wf.role_w, wf.location_w, wf.tenure_w, wf.license_w FROM roster r LEFT JOIN base_qtd b ON b.tm_id = r.id LEFT JOIN actual_base_this_week abt ON abt.tm_id = r.id LEFT JOIN actuals_through_current a ON a.tm_id = r.id LEFT JOIN prior_paid pp ON pp.tm_id = r.id LEFT JOIN sp_rolling sr ON sr.tm_id = r.id LEFT JOIN wh_final wf ON wf.tm_id = r.id),
  team_totals AS (SELECT SUM(c.c_qtd_base_paid) AS qtd_base_paid_total, SUM(c.c_qtd_base_in_pool) AS qtd_base_in_pool_total, SUM(c.c_qtd_growth_budget) AS qtd_growth_budget_total, SUM(c.c_qtd_mgr) AS qtd_mgr_total, SUM(c.c_qtd_hdb) AS qtd_hdb_total, SUM(c.c_qtd_comm) AS qtd_comm_total, SUM(c.c_curr_qtd_sp) AS qtd_sp_total, SUM(CASE WHEN c.r_role_category = 'Sales' THEN c.c_curr_qtd_sp ELSE 0 END) AS qtd_sp_sales_only, SUM(c.c_avg_13wk) AS team_avg_13wk, SUM(c.c_avg_4wk) AS team_avg_4wk, SUM(c.c_weighted_hours) AS wh_total, SUM(COALESCE(c.weekly_health_benefit_agency_paid, 0)) AS team_weekly_health, COALESCE(jsonb_agg(jsonb_build_object('team_member_id', c.tm_id, 'name', c.first_name || ' ' || c.last_name, 'weekly_health', COALESCE(c.weekly_health_benefit_agency_paid, 0)) ORDER BY c.first_name), '[]'::jsonb) AS per_person_health_detail FROM combined c),
  pool_calc AS (SELECT tt.*, pwq.*, v_qtd_envelope AS qtd_envelope, v_qtd_wc AS qtd_wc, tt.team_weekly_health * v_week_of_cycle AS qtd_health_total, GREATEST(0, (v_qtd_envelope - v_qtd_wc - (tt.team_weekly_health * v_week_of_cycle)) / (1.0 + v_burden_mult) - tt.qtd_base_in_pool_total - tt.qtd_comm_total - tt.qtd_mgr_total - v_qtd_hdb_max - pwq.qtd_prize_cart - pwq.qtd_wtq_trip - pwq.qtd_goals_total) AS qtd_bonus_pool FROM team_totals tt CROSS JOIN prize_wtq_qtd pwq),
  pool_split AS (SELECT pc.*, pc.qtd_bonus_pool / 3.0 AS qtd_retention_pool, pc.qtd_bonus_pool / 3.0 AS qtd_sp_13wk_pool, pc.qtd_bonus_pool / 3.0 AS qtd_sp_4wk_pool FROM pool_calc pc),
  distributed AS (SELECT c.*, ps.*, CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END AS ret_share_ratio, CASE WHEN ps.team_avg_13wk > 0 THEN c.c_avg_13wk / ps.team_avg_13wk ELSE 0 END AS sp13_share_ratio, CASE WHEN ps.team_avg_4wk > 0 THEN c.c_avg_4wk / ps.team_avg_4wk ELSE 0 END AS sp4_share_ratio FROM combined c CROSS JOIN pool_split ps),
  earned AS (SELECT d.*, d.ret_share_ratio * d.qtd_retention_pool AS qtd_ret_earned, d.sp13_share_ratio * d.qtd_sp_13wk_pool AS qtd_sp13_earned, d.sp4_share_ratio * d.qtd_sp_4wk_pool AS qtd_sp4_earned, (d.ret_share_ratio * d.qtd_retention_pool + d.sp13_share_ratio * d.qtd_sp_13wk_pool + d.sp4_share_ratio * d.qtd_sp_4wk_pool) AS qtd_bonus_earned, (d.sp13_share_ratio * d.qtd_sp_13wk_pool + d.sp4_share_ratio * d.qtd_sp_4wk_pool) AS qtd_sales_share, (d.ret_share_ratio * d.qtd_retention_pool) AS qtd_retention_share FROM distributed d),
  settled AS (SELECT e.*, GREATEST(0, e.qtd_bonus_earned - e.c_prior_qtd_bonus) AS this_week_bonus, GREATEST(0, e.qtd_sales_share - e.c_prior_qtd_sales) AS this_week_sales_share, GREATEST(0, e.qtd_retention_share - e.c_prior_qtd_retention) AS this_week_retention_share FROM earned e),
  weekly_pool_totals AS (SELECT SUM(this_week_sales_share) AS weekly_sales_pool_sum, SUM(this_week_retention_share) AS weekly_retention_pool_sum, SUM(this_week_bonus) AS weekly_bonus_pool_sum FROM settled)
  SELECT s.tm_id, (s.first_name || ' ' || s.last_name)::text, s.r_role::text, s.r_role_category::text, s.r_role_level::text,
    ROUND(CASE WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 52 WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40 * 52 ELSE 0 END, 2) AS annual_base_salary,
    ROUND(s.c_actual_base_this_week, 2) AS weekly_base_salary,
    ROUND(s.c_curr_qtd_sp * 4, 2) AS annual_commission_projected, ROUND(s.c_curr_comm, 2) AS weekly_commission_projected, ROUND(s.c_curr_qtd_sp, 2) AS ytd_sales_points,
    ROUND(CASE WHEN (s.team_avg_13wk + s.team_avg_4wk) > 0 THEN (s.c_avg_13wk + s.c_avg_4wk) / (s.team_avg_13wk + s.team_avg_4wk) ELSE 0 END * 100, 4) AS sales_points_share_pct,
    ROUND(s.c_weighted_hours, 4) AS weighted_hours_at_40, ROUND(s.ret_share_ratio * 100, 4) AS retention_hours_share_pct,
    ROUND(CASE WHEN s.qtd_bonus_pool > 0 THEN s.qtd_bonus_earned / s.qtd_bonus_pool ELSE 0 END * 100, 4) AS person_share_pct,
    ROUND(s.qtd_bonus_earned * 4, 2) AS annual_bonus, ROUND(s.this_week_bonus, 2) AS weekly_bonus, ROUND(s.this_week_sales_share, 2) AS weekly_sales_pool_share, ROUND(s.this_week_retention_share, 2) AS weekly_retention_pool_share,
    ROUND(CASE WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 52 WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40 * 52 ELSE 0 END + s.c_curr_qtd_sp * 4 + s.qtd_bonus_earned * 4, 2) AS annual_total_comp,
    ROUND(s.c_actual_base_this_week + s.c_curr_comm + s.this_week_bonus, 2) AS weekly_total_comp,
    jsonb_build_object('commission_semantic', 'wctd.commission column = weekly-earned SP $ (1 SP = $1)', 'design_note', 'Snapshot-aware. Goals-bonus + HDB carve-and-forget at MAX. HOURLY key added to payroll_detail base-pay extraction (2026-07-14 pm4) to cover new payroll format alongside SALARY/REGULAR.', 'person_pay_type', s.pay_type, 'person_pay_rate', s.pay_rate, 'actual_base_this_week', ROUND(s.c_actual_base_this_week, 2), 'weight_factors', jsonb_build_object('hours_baseline', 40.0, 'role_w', s.role_w, 'location_w', s.location_w, 'tenure_w', s.tenure_w, 'license_w', s.license_w), 'quarter', jsonb_build_object('year', v_year, 'quarter', v_quarter, 'pool_start', v_cycle_start, 'pool_end', v_cycle_end, 'weeks_elapsed_qtd', v_week_of_cycle, 'weeks_in_quarter', v_weeks_in_cycle), 'envelope', jsonb_build_object('annual_basis', ROUND(v_annual_basis, 2), 'current_pool_pct', v_current_pool_pct, 'weekly_envelope', ROUND(v_weekly_envelope, 2), 'qtd_envelope', ROUND(s.qtd_envelope, 2), 'quarterly_envelope', ROUND(v_cycle_envelope, 2)), 'qtd_subtractions', jsonb_build_object('qtd_wc', ROUND(s.qtd_wc, 2), 'qtd_actual_health', ROUND(s.qtd_health_total, 2), 'qtd_manager_bonus_actual', ROUND(s.qtd_mgr_total, 2), 'qtd_hdb_actual', ROUND(s.qtd_hdb_total, 2), 'qtd_hdb_max_accrual', ROUND(v_qtd_hdb_max, 2), 'qtd_prize_cart_accrual', ROUND(s.qtd_prize_cart, 2), 'qtd_wtq_trip_accrual', ROUND(s.qtd_wtq_trip, 2), 'qtd_goals_total_accrual', ROUND(s.qtd_goals_total, 2), 'qtd_wtw_bonus_accrual', ROUND(s.qtd_wtw_bonus, 2), 'qtd_gain_bonus_accrual', ROUND(s.qtd_gain_bonus, 2), 'qtd_leaderboard_bonus_accrual', ROUND(s.qtd_leaderboard_bonus, 2), 'qtd_all_star_bonus_accrual', ROUND(s.qtd_all_star_bonus, 2), 'qtd_trailblazer_bonus_accrual', ROUND(s.qtd_trailblazer_bonus, 2), 'qtd_base_in_pool', ROUND(s.qtd_base_in_pool_total, 2), 'qtd_actual_base_paid', ROUND(s.qtd_base_paid_total, 2), 'qtd_growth_budget', ROUND(s.qtd_growth_budget_total, 2), 'qtd_actual_commission', ROUND(s.qtd_comm_total, 2), 'qtd_actual_commission_source', 'wctd.commission SUM through current week; eats WHOLE pool', 'qtd_burden', ROUND((s.qtd_base_in_pool_total + s.qtd_comm_total + s.qtd_mgr_total + v_qtd_hdb_max + s.qtd_prize_cart + s.qtd_wtq_trip + s.qtd_goals_total + s.qtd_bonus_pool) * v_burden_mult, 2)), 'qtd_pools', jsonb_build_object('qtd_bonus_pool', ROUND(s.qtd_bonus_pool, 2), 'qtd_retention_pool', ROUND(s.qtd_retention_pool, 2), 'qtd_sp_13wk_pool', ROUND(s.qtd_sp_13wk_pool, 2), 'qtd_sp_4wk_pool', ROUND(s.qtd_sp_4wk_pool, 2), 'split_thirds', true), 'weekly_settlement', jsonb_build_object('weekly_sales_pool', ROUND((SELECT weekly_sales_pool_sum FROM weekly_pool_totals), 2), 'weekly_retention_pool', ROUND((SELECT weekly_retention_pool_sum FROM weekly_pool_totals), 2), 'weekly_bonus_pool', ROUND((SELECT weekly_bonus_pool_sum FROM weekly_pool_totals), 2)), 'weekly_sales_pool', ROUND((SELECT weekly_sales_pool_sum FROM weekly_pool_totals), 2), 'weekly_retention_pool', ROUND((SELECT weekly_retention_pool_sum FROM weekly_pool_totals), 2), 'carveouts_outside_pool', jsonb_build_object('annual_dollars', ROUND((v_weekly_apparel + v_weekly_life_ins + v_weekly_cc_reserve) * 52, 2), 'quarterly_dollars', ROUND((v_weekly_apparel + v_weekly_life_ins + v_weekly_cc_reserve) * 13, 2), 'weekly_dollars', ROUND(v_weekly_apparel + v_weekly_life_ins + v_weekly_cc_reserve, 2), 'qtd_dollars', ROUND(v_qtd_apparel + v_qtd_life_ins + v_qtd_cc_reserve, 2), 'note', 'Agency-funded team benefits outside residual pool.', 'items', jsonb_build_object('apparel', jsonb_build_object('weekly_dollars', ROUND(v_weekly_apparel, 2), 'qtd_dollars', ROUND(v_qtd_apparel, 2), 'annual_dollars', ROUND(v_weekly_apparel * 52, 2)), 'life_insurance_stipend', jsonb_build_object('weekly_dollars', ROUND(v_weekly_life_ins, 2), 'qtd_dollars', ROUND(v_qtd_life_ins, 2), 'annual_dollars', ROUND(v_weekly_life_ins * 52, 2)), 'champions_circle_reserve', jsonb_build_object('weekly_dollars', ROUND(v_weekly_cc_reserve, 2), 'qtd_dollars', ROUND(v_qtd_cc_reserve, 2), 'annual_dollars', ROUND(v_weekly_cc_reserve * 52, 2)))), 'team_totals', jsonb_build_object('qtd_actual_base_paid', ROUND(s.qtd_base_paid_total, 2), 'qtd_base_in_pool', ROUND(s.qtd_base_in_pool_total, 2), 'qtd_growth_budget', ROUND(s.qtd_growth_budget_total, 2), 'qtd_actual_health', ROUND(s.qtd_health_total, 2), 'team_weekly_health', ROUND(s.team_weekly_health, 2), 'per_person_health', s.per_person_health_detail, 'qtd_actual_commission', ROUND(s.qtd_comm_total, 2), 'qtd_manager_bonus', ROUND(s.qtd_mgr_total, 2), 'qtd_hdb', ROUND(s.qtd_hdb_total, 2), 'qtd_sp_total', ROUND(s.qtd_sp_total, 2), 'qtd_sp_sales_only', ROUND(s.qtd_sp_sales_only, 2), 'team_avg_13wk', ROUND(s.team_avg_13wk, 2), 'team_avg_4wk', ROUND(s.team_avg_4wk, 2), 'wh_total', ROUND(s.wh_total, 4)), 'person_qtd', jsonb_build_object('qtd_actual_base_paid', ROUND(s.c_qtd_base_paid, 2), 'qtd_base_in_pool', ROUND(s.c_qtd_base_in_pool, 2), 'qtd_growth_budget', ROUND(s.c_qtd_growth_budget, 2), 'actual_base_this_week', ROUND(s.c_actual_base_this_week, 2), 'qtd_manager_bonus', ROUND(s.c_qtd_mgr, 2), 'qtd_hdb', ROUND(s.c_qtd_hdb, 2), 'qtd_commission', ROUND(s.c_qtd_comm, 2), 'qtd_sp', ROUND(s.c_curr_qtd_sp, 2), 'rolling_13wk_avg_sp', ROUND(s.c_avg_13wk, 2), 'rolling_4wk_avg_sp', ROUND(s.c_avg_4wk, 2), 'qtd_ret_earned', ROUND(s.qtd_ret_earned, 2), 'qtd_sp13_earned', ROUND(s.qtd_sp13_earned, 2), 'qtd_sp4_earned', ROUND(s.qtd_sp4_earned, 2), 'qtd_sales_share', ROUND(s.qtd_sales_share, 2), 'qtd_retention_share', ROUND(s.qtd_retention_share, 2), 'qtd_bonus_earned', ROUND(s.qtd_bonus_earned, 2), 'prior_qtd_bonus_paid', ROUND(s.c_prior_qtd_bonus, 2), 'prior_qtd_sales_paid', ROUND(s.c_prior_qtd_sales, 2), 'prior_qtd_retention_paid', ROUND(s.c_prior_qtd_retention, 2), 'this_week_bonus_settlement', ROUND(s.this_week_bonus, 2), 'this_week_sales_settlement', ROUND(s.this_week_sales_share, 2), 'this_week_retention_settlement', ROUND(s.this_week_retention_share, 2), 'ret_share_ratio_pct', ROUND(s.ret_share_ratio * 100, 4), 'sp13_share_ratio_pct', ROUND(s.sp13_share_ratio * 100, 4), 'sp4_share_ratio_pct', ROUND(s.sp4_share_ratio * 100, 4)), 'constants', jsonb_build_object('sales_weight', 0.6667, 'retention_weight', 0.3333, 'burden_multiplier', v_burden_mult, 'wc_annual', v_wc_annual, 'split_thirds', true), 'pool_basis', v_pool_result->'basis', 'schedule', v_pool_result->'schedule', 'carveouts_detail', v_carveouts_result)
  FROM settled s ORDER BY s.last_name;
END;
$function$;

CREATE OR REPLACE FUNCTION public.compute_weekly_pay(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, weekly_pay numeric, base_advance numeric, health_bonus numeric, service_surge_share numeric, true_pay_bonus numeric, manager_bonus numeric, agency_profit_share numeric, diagnostics jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_week_start_date    date := p_week_ending_date - 6;
  v_cycle_start        date;
  v_prior_qtr_end      date;
  v_retention_jsonb    jsonb;
  v_annual_budget      numeric;
  v_weekly_budget      numeric;
  v_scorecard          jsonb;
  v_scorecard_annual   numeric;
  v_team_total_sp      numeric;
  v_required_count_avg numeric;
  v_weeks_elapsed      int;
  v_manager_baseline   numeric;
BEGIN
  SELECT cci.cycle_start INTO v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_ending_date) cci;
  v_prior_qtr_end := v_cycle_start - 1;

  v_weeks_elapsed := GREATEST(1, FLOOR((p_week_ending_date - v_cycle_start)::numeric / 7.0)::int + 1);

  v_retention_jsonb := public.compute_retention_budget_weekly(p_agency_id, p_week_ending_date);
  v_annual_budget   := NULLIF(v_retention_jsonb->>'budget','')::numeric;
  v_weekly_budget   := v_annual_budget / 52.0;
  v_scorecard       := public.compute_scorecard_bonus(p_agency_id, p_week_ending_date);
  v_scorecard_annual := NULLIF(v_scorecard->>'bonus_projected','')::numeric;

  SELECT COALESCE(SUM(wctd.sales_points), 0) INTO v_team_total_sp
    FROM public.weekly_cpr_team_detail wctd
    JOIN public.weekly_cpr_reports     r ON r.id = wctd.weekly_cpr_report_id
    JOIN public.team                   t ON t.id = wctd.team_member_id
   WHERE r.agency_id = p_agency_id
     AND r.week_ending_date = p_week_ending_date
     AND t.category = 'agency'
     AND t.is_admin_backoffice = false
     AND COALESCE(t.role_level,'') <> 'Owner';

  SELECT AVG(required_sales_members_count)::numeric INTO v_required_count_avg
    FROM public.weekly_cpr_reports
   WHERE agency_id = p_agency_id
     AND week_ending_date >= v_cycle_start
     AND week_ending_date <= p_week_ending_date
     AND required_sales_members_count IS NOT NULL;

  v_manager_baseline := CASE WHEN COALESCE(v_required_count_avg, 0) > 0
    THEN v_team_total_sp / v_required_count_avg / v_weeks_elapsed::numeric
    ELSE 0
  END;

  RETURN QUERY
  WITH health_hits AS (
    SELECT * FROM public.compute_team_health_weekly_hits(p_agency_id, p_week_ending_date)
  ),
  base AS (
    SELECT wctd.team_member_id,
      COALESCE(wctd.sales_points,0) AS this_week_qtd_sp,
      wctd.payroll_ytd_paid AS this_week_payroll_ytd,
      COALESCE((
        SELECT SUM(COALESCE(prior.health_bonus,0) + COALESCE(prior.service_surge_share,0) + COALESCE(prior.manager_bonus,0))
        FROM public.weekly_cpr_team_detail prior
        JOIN public.weekly_cpr_reports     prior_r ON prior_r.id = prior.weekly_cpr_report_id
        WHERE prior_r.agency_id = p_agency_id
          AND prior_r.week_ending_date >= v_cycle_start
          AND prior_r.week_ending_date <  p_week_ending_date
          AND prior.team_member_id = wctd.team_member_id
      ), 0) AS hsm_prior_total,
      COALESCE((
        SELECT SUM(COALESCE(prior.weekly_pay,0))
        FROM public.weekly_cpr_team_detail prior
        JOIN public.weekly_cpr_reports     prior_r ON prior_r.id = prior.weekly_cpr_report_id
        WHERE prior_r.agency_id = p_agency_id
          AND prior_r.week_ending_date >= v_cycle_start
          AND prior_r.week_ending_date <  p_week_ending_date
          AND prior.team_member_id = wctd.team_member_id
      ), 0) AS prior_wp_total,
      (SELECT anchor_d.payroll_ytd_paid
         FROM public.weekly_cpr_team_detail anchor_d
         JOIN public.weekly_cpr_reports     anchor_r ON anchor_r.id = anchor_d.weekly_cpr_report_id
        WHERE anchor_r.agency_id = p_agency_id
          AND anchor_r.week_ending_date = v_prior_qtr_end
          AND anchor_d.team_member_id = wctd.team_member_id) AS prior_qtr_end_payroll_ytd,
      t.role, t.role_level, t.role_category, t.category, t.pay_type, t.pay_rate, t.work_location, t.start_date,
      t.license_pc, t.license_lh, t.license_ips,
      CASE WHEN t.role='Reception' THEN COALESCE((
          SELECT SUM(EXTRACT(EPOCH FROM (tce.clock_out_at-tce.clock_in_at))/3600.0)
          FROM public.time_clock_entries tce
          WHERE tce.agency_id=p_agency_id AND tce.team_member_id=t.id
            AND tce.clock_in_at >= (v_week_start_date::timestamp AT TIME ZONE 'America/Chicago')
            AND tce.clock_in_at <  ((p_week_ending_date+1)::timestamp AT TIME ZONE 'America/Chicago')
            AND tce.clock_out_at IS NOT NULL), 0) ELSE NULL END AS reception_hours,
      COALESCE((SELECT SUM(CASE WHEN tor.partial_day IN ('morning','afternoon') THEN 4 ELSE 8 END
          * (SELECT COUNT(*)::int FROM generate_series(GREATEST(tor.start_date,v_week_start_date),
               LEAST(tor.end_date,p_week_ending_date), '1 day'::interval) d
             WHERE EXTRACT(DOW FROM d) BETWEEN 1 AND 5))
        FROM public.time_off_requests tor
        WHERE tor.agency_id=p_agency_id AND tor.requester_team_id=t.id AND tor.status='approved'
          AND tor.start_date<=p_week_ending_date AND tor.end_date>=v_week_start_date AND tor.is_paid=true),0) AS paid_off_hours,
      COALESCE((SELECT SUM(CASE WHEN tor.partial_day IN ('morning','afternoon') THEN 4 ELSE 8 END
          * (SELECT COUNT(*)::int FROM generate_series(GREATEST(tor.start_date,v_week_start_date),
               LEAST(tor.end_date,p_week_ending_date), '1 day'::interval) d
             WHERE EXTRACT(DOW FROM d) BETWEEN 1 AND 5))
        FROM public.time_off_requests tor
        WHERE tor.agency_id=p_agency_id AND tor.requester_team_id=t.id AND tor.status='approved'
          AND tor.start_date<=p_week_ending_date AND tor.end_date>=v_week_start_date AND tor.is_paid=false),0) AS unpaid_off_hours,
      COALESCE(hh.hits, 0) AS week_health_days,
      COALESCE((SELECT wctd_last.sales_points FROM public.weekly_cpr_team_detail wctd_last
        JOIN public.weekly_cpr_reports r_last ON r_last.id=wctd_last.weekly_cpr_report_id
        WHERE r_last.agency_id=p_agency_id AND r_last.week_ending_date=p_week_ending_date-7
          AND wctd_last.team_member_id=t.id),0) AS last_week_qtd_sp
    FROM public.weekly_cpr_team_detail wctd
    JOIN public.weekly_cpr_reports     r ON r.id=wctd.weekly_cpr_report_id
    JOIN public.team                   t ON t.id=wctd.team_member_id
    LEFT JOIN health_hits              hh ON hh.team_id = t.id
    WHERE r.agency_id=p_agency_id 
      AND r.week_ending_date=p_week_ending_date
      AND t.is_admin_backoffice = false),
  hours AS (SELECT b.*,
      CASE WHEN b.role='Reception' THEN ROUND(b.reception_hours, 2)
           ELSE ROUND(GREATEST(0, 40.0 - b.paid_off_hours - b.unpaid_off_hours), 2) END AS hours_for_surge,
      ROUND(b.reception_hours, 2) AS hourly_hours,
      GREATEST(0,(40.0-b.unpaid_off_hours)/40.0) AS salaried_paid_fraction FROM base b),
  weighted AS (SELECT h.*,
      CASE WHEN h.role='Reception' THEN 1.00 WHEN h.role IN ('Outbound','Inbound') THEN 0.25 ELSE 0 END AS role_w,
      CASE WHEN h.work_location='in_office' THEN 1.00 WHEN h.work_location='remote' THEN 0.75 ELSE 1.00 END AS location_w,
      LEAST(1.00,GREATEST(0,FLOOR((p_week_ending_date-h.start_date)::numeric/7.0)/52.0)) AS tenure_w,
      LEAST(1.00,0.50 + CASE WHEN h.license_pc THEN 0.35 ELSE 0 END
                       + CASE WHEN h.license_lh THEN 0.10 ELSE 0 END
                       + CASE WHEN h.license_ips THEN 0.05 ELSE 0 END) AS license_w,
      (h.category<>'admin' AND COALESCE(h.role_level,'')<>'Owner' AND h.hours_for_surge>0) AS surge_eligible
    FROM hours h),
  weighted2 AS (SELECT w.*,
      CASE WHEN w.surge_eligible THEN w.hours_for_surge*w.role_w*w.location_w*w.tenure_w*w.license_w ELSE 0 END AS weighted_hours
    FROM weighted w),
  totals AS (SELECT COALESCE(SUM(weighted_hours),0) AS total_weighted_hours,
      COALESCE(SUM(CASE WHEN role='Reception' AND pay_type='HOURLY' THEN pay_rate*hourly_hours ELSE 0 END),0) AS reception_wages_this_week
    FROM weighted2),
  pool AS (SELECT total_weighted_hours, reception_wages_this_week,
      GREATEST(0,COALESCE(v_weekly_budget,0)-reception_wages_this_week) AS surge_pool FROM totals),
  computed AS (SELECT
      w.team_member_id, w.role, w.role_level, w.role_category, w.pay_type, w.pay_rate,
      w.this_week_qtd_sp, w.last_week_qtd_sp,
      w.this_week_payroll_ytd, w.prior_qtr_end_payroll_ytd,
      w.hsm_prior_total, w.prior_wp_total,
      CASE WHEN w.this_week_payroll_ytd IS NULL OR w.prior_qtr_end_payroll_ytd IS NULL
           THEN NULL ELSE ROUND(w.this_week_payroll_ytd - w.prior_qtr_end_payroll_ytd, 2) END AS qtd_paid,
      w.week_health_days, w.surge_eligible,
      w.weighted_hours, w.hours_for_surge, w.hourly_hours, w.salaried_paid_fraction,
      w.paid_off_hours, w.unpaid_off_hours, p.surge_pool, p.total_weighted_hours, p.reception_wages_this_week,
      ROUND(CASE WHEN w.pay_type='HOURLY' THEN w.pay_rate*w.hourly_hours ELSE w.pay_rate*w.salaried_paid_fraction END, 2) AS c_weekly_pay,
      ROUND(CASE
          WHEN w.role_category <> 'Sales' THEN 0
          WHEN w.role_level IN ('Unit Manager', 'Team Manager', 'Section Manager', 'Office Manager')
            THEN 0.10 * v_manager_baseline
          ELSE 0.10 * GREATEST(0, w.this_week_qtd_sp - w.last_week_qtd_sp) END, 2) AS c_base_advance,
      ROUND(CASE WHEN w.week_health_days>=5 THEN 25.00 ELSE 0 END, 2) AS c_health_bonus,
      ROUND(CASE WHEN p.total_weighted_hours>0 THEN (w.weighted_hours/p.total_weighted_hours)*p.surge_pool ELSE 0 END, 2) AS c_service_surge_share,
      ROUND(CASE w.role_level
          WHEN 'Unit Manager'    THEN COALESCE(v_scorecard_annual,0)*0.001
          WHEN 'Team Manager'    THEN COALESCE(v_scorecard_annual,0)*0.002
          WHEN 'Section Manager' THEN COALESCE(v_scorecard_annual,0)*0.002
          WHEN 'Office Manager'  THEN COALESCE(v_scorecard_annual,0)*0.003
          ELSE 0::numeric END, 2) AS c_manager_bonus,
      0::numeric AS c_agency_profit_share
    FROM weighted2 w CROSS JOIN pool p)
  SELECT c.team_member_id, c.c_weekly_pay, c.c_base_advance, c.c_health_bonus, c.c_service_surge_share,
    CASE WHEN c.this_week_payroll_ytd IS NULL OR c.prior_qtr_end_payroll_ytd IS NULL THEN NULL
         ELSE ROUND(GREATEST(0,
           (c.this_week_qtd_sp + c.hsm_prior_total
            + CASE WHEN c.role_category = 'Retention' THEN c.prior_wp_total ELSE 0 END)
           - c.qtd_paid
           - CASE WHEN c.role_category = 'Retention' THEN 0 ELSE c.c_weekly_pay END
           - c.c_base_advance - c.c_agency_profit_share), 2)
    END AS true_pay_bonus,
    c.c_manager_bonus, c.c_agency_profit_share,
    jsonb_build_object(
      'role_level', c.role_level, 'role_category', c.role_category,
      'this_week_qtd_sp', c.this_week_qtd_sp, 'last_week_qtd_sp', c.last_week_qtd_sp,
      'wow_sp_increase', GREATEST(0, c.this_week_qtd_sp - c.last_week_qtd_sp),
      'team_total_sp', v_team_total_sp, 'required_count_avg', v_required_count_avg,
      'weeks_elapsed', v_weeks_elapsed, 'manager_baseline', v_manager_baseline,
      'cycle_start', v_cycle_start, 'prior_qtr_end_anchor_date', v_prior_qtr_end,
      'this_week_payroll_ytd', c.this_week_payroll_ytd,
      'prior_qtr_end_payroll_ytd', c.prior_qtr_end_payroll_ytd,
      'qtd_paid', c.qtd_paid, 'hsm_prior_total', c.hsm_prior_total,
      'prior_wp_total', c.prior_wp_total,
      'earned_pool', c.this_week_qtd_sp + c.hsm_prior_total
                   + CASE WHEN c.role_category = 'Retention' THEN c.prior_wp_total ELSE 0 END,
      'wp_subtracted', CASE WHEN c.role_category = 'Retention' THEN 0 ELSE c.c_weekly_pay END,
      'this_week_total_non_tpb', c.c_weekly_pay + c.c_base_advance + c.c_health_bonus
        + c.c_service_surge_share + c.c_manager_bonus + c.c_agency_profit_share,
      'paid_off_hours', c.paid_off_hours, 'unpaid_off_hours', c.unpaid_off_hours,
      'hours_for_surge', c.hours_for_surge, 'hourly_hours', c.hourly_hours,
      'salaried_paid_fraction', c.salaried_paid_fraction,
      'week_health_days', c.week_health_days,
      'surge_eligible', c.surge_eligible, 'weighted_hours', c.weighted_hours,
      'inputs', jsonb_build_object(
        'annual_retention_budget', v_annual_budget,
        'weekly_retention_budget', v_weekly_budget,
        'reception_wages_this_week', c.reception_wages_this_week,
        'surge_pool', c.surge_pool, 'total_weighted_hours', c.total_weighted_hours,
        'scorecard_annual_projected', v_scorecard_annual)
    ) AS diagnostics
  FROM computed c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.time_off_check_coverage(p_agency_id uuid, p_start_date date, p_end_date date, p_exclude_request_id uuid DEFAULT NULL::uuid, p_request_type text DEFAULT NULL::text, p_requester_team_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_active_team_count integer;
  v_overlapping_off integer;
  v_overlapping_off_aa integer;
  v_overlapping_off_outbound_am integer;
  v_severity text := 'green';
  v_messages text[] := ARRAY[]::text[];
BEGIN
  SELECT COUNT(*)::int INTO v_active_team_count
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant');

  WITH overlapping AS (
    SELECT t.role, t.role_level, t.first_name, t.last_name, r.start_date, r.end_date, r.request_type
    FROM public.time_off_requests r
    JOIN public.team t ON t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status IN ('approved', 'voting', 'awaiting_decision')
      AND r.id IS DISTINCT FROM p_exclude_request_id
      AND r.requester_team_id IS DISTINCT FROM p_requester_team_id
      AND tsrange(r.start_date::timestamp, (r.end_date + 1)::timestamp, '[)')
          && tsrange(p_start_date::timestamp, (p_end_date + 1)::timestamp, '[)')
      AND r.request_type IN ('time_off_full_day','time_off_half_day','sick','remote_day','remote_half_day')
  )
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE role_level = 'Account Associate'),
    COUNT(*) FILTER (WHERE role_level = 'Account Manager' AND role = 'Outbound')
  INTO v_overlapping_off, v_overlapping_off_aa, v_overlapping_off_outbound_am
  FROM overlapping;

  IF v_active_team_count - v_overlapping_off - 1 < 1 THEN
    v_severity := 'red';
    v_messages := array_append(v_messages,
      'RED: Approving would leave zero team members in office during business hours');
  END IF;

  IF v_overlapping_off_aa >= 1
     AND p_request_type IN ('time_off_full_day','time_off_half_day','sick','remote_day','remote_half_day')
     AND EXISTS (SELECT 1 FROM public.team WHERE id = p_requester_team_id AND role_level = 'Account Associate') THEN
    IF v_severity = 'green' THEN v_severity := 'yellow'; END IF;
    v_messages := array_append(v_messages,
      'YELLOW: Both Account Associates would be off — no primary/secondary reception coverage');
  END IF;

  IF v_overlapping_off_outbound_am >= 1
     AND p_request_type IN ('time_off_full_day','time_off_half_day','sick','remote_day','remote_half_day')
     AND EXISTS (SELECT 1 FROM public.team WHERE id = p_requester_team_id AND role_level = 'Account Manager' AND role = 'Outbound') THEN
    IF v_severity = 'green' THEN v_severity := 'yellow'; END IF;
    v_messages := array_append(v_messages,
      'YELLOW: Multiple Outbound AMs off the same week — weekly QUOTE pace at risk');
  END IF;

  RETURN jsonb_build_object(
    'severity', v_severity,
    'messages', v_messages,
    'active_team_count', v_active_team_count,
    'overlapping_off_total', v_overlapping_off,
    'overlapping_off_account_associates', v_overlapping_off_aa,
    'overlapping_off_outbound_ams', v_overlapping_off_outbound_am
  );
END;
$function$;

-- 5. Rewrite the view (v_producer_roi_inputs) with strings swapped
CREATE OR REPLACE VIEW public.v_producer_roi_inputs AS
 WITH cfg AS (
         SELECT a.id AS agency_id,
            COALESCE(a.smvc_rate_pc, 0.10) AS smvc_rate_pc,
            COALESCE(a.blended_rate_other, 0.09) AS blended_rate_other,
            COALESCE(( SELECT compute_lapse_rate.annualized_rate
                   FROM compute_lapse_rate(a.id) compute_lapse_rate(line, starting_pif, lost_ytd, days_elapsed, ytd_rate, annualized_rate, source_snapshot_date)
                  WHERE (compute_lapse_rate.line = 'blended'::text)), 0.11) AS lapse_rate_annual,
            COALESCE(a.payroll_burden_multiplier, 1.15) AS burden,
            a.rates_are_defaults
           FROM agency a
        ), team_cost AS (
         SELECT t.id AS team_member_id,
            t.agency_id,
            ((t.first_name || ' '::text) || t.last_name) AS producer_name,
            t.role,
            t.pay_type,
            t.pay_rate,
            t.pay_frequency,
            t.role_level,
                CASE lower(COALESCE(t.pay_frequency, 'weekly'::text))
                    WHEN 'weekly'::text THEN (t.pay_rate * (52)::numeric)
                    WHEN 'biweekly'::text THEN (t.pay_rate * (26)::numeric)
                    WHEN 'semimonthly'::text THEN (t.pay_rate * (24)::numeric)
                    WHEN 'monthly'::text THEN (t.pay_rate * (12)::numeric)
                    WHEN 'annual'::text THEN t.pay_rate
                    WHEN 'hourly'::text THEN (t.pay_rate * (2080)::numeric)
                    ELSE (t.pay_rate * (52)::numeric)
                END AS annual_pay
           FROM team t
          WHERE ((t.is_active = true) AND (t.archived_at IS NULL) AND (t.category = 'agency'::text))
        ), recent AS (
         SELECT pp.team_member_id,
            pp.agency_id,
            sum(pp.premium_issued) AS new_premium_3mo,
            (sum(pp.premium_issued) / 3.0) AS new_premium_monthly_avg,
            count(DISTINCT ((pp.period_year || '-'::text) || pp.period_month)) AS months_counted
           FROM producer_production pp
          WHERE ((pp.premium_type = 'new'::text) AND (make_date(pp.period_year, pp.period_month, 1) >= (date_trunc('month'::text, (CURRENT_DATE)::timestamp with time zone) - '3 mons'::interval)))
          GROUP BY pp.team_member_id, pp.agency_id
        )
 SELECT tc.team_member_id,
    tc.agency_id,
    tc.producer_name,
    tc.role,
    tc.annual_pay,
    round((tc.annual_pay * cfg.burden), 2) AS fully_loaded_annual_cost,
    round(((tc.annual_pay * cfg.burden) / (12)::numeric), 2) AS fully_loaded_monthly_cost,
    COALESCE(round(r.new_premium_monthly_avg, 2), (0)::numeric) AS new_premium_monthly_avg,
    cfg.smvc_rate_pc,
    cfg.lapse_rate_annual,
    cfg.burden,
    cfg.rates_are_defaults,
    COALESCE(round((r.new_premium_monthly_avg * cfg.smvc_rate_pc), 2), (0)::numeric) AS monthly_new_commission,
    COALESCE(round((((r.new_premium_monthly_avg * (12)::numeric) * cfg.smvc_rate_pc) * ((1)::numeric - cfg.lapse_rate_annual)), 2), (0)::numeric) AS yr1_renewal_commission_est,
    tc.role_level
   FROM ((team_cost tc
     LEFT JOIN cfg ON ((cfg.agency_id = tc.agency_id)))
     LEFT JOIN recent r ON ((r.team_member_id = tc.team_member_id)))
  WHERE (tc.role = ANY (ARRAY['Outbound'::text, 'Inbound'::text, 'Owner'::text]));

COMMIT;
