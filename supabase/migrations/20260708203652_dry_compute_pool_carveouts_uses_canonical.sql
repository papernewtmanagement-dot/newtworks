-- Tier-3 DRY: compute_pool_carveouts roster hand-rolls -> get_expected_teammates.
-- Applied 2026-07-08. Parity verified byte-exact against baseline (Manager Bonus
-- $642.07, Life Ins $4,800, Apparel $600, HDB $5,200, total_annual_carveouts
-- $15,318.02 pre and post).
--
-- 4 scans consolidated:
--   Manager Bonus  -> time_off_participant + WHERE role_level IN (Unit/Section/Office Manager)
--   Life Insurance -> time_off_participant + start_date IS NOT NULL
--   Apparel        -> time_off_participant + start_date IS NOT NULL
--   Health Dev     -> time_off_participant

CREATE OR REPLACE FUNCTION public.compute_pool_carveouts(p_agency_id UUID, p_week_end_date DATE)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
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
  v_cc_reconciliation_credit numeric := 0;
  v_cc_reconciliation_detail jsonb := '[]'::jsonb;
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

  -- MANAGER BONUS (roster via canonical: time_off_participant filtered to manager role_levels)
  SELECT
    COALESCE(SUM(CASE et.role_level WHEN 'Unit Manager' THEN 0.001 WHEN 'Section Manager' THEN 0.002 WHEN 'Office Manager' THEN 0.003 ELSE 0 END * 52.0 * v_annual_ot_scorecard), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', et.team_id, 'name', et.first_name || ' ' || et.last_name, 'role_level', et.role_level,
      'weekly_rate_pct', CASE et.role_level WHEN 'Unit Manager' THEN 0.1 WHEN 'Section Manager' THEN 0.2 WHEN 'Office Manager' THEN 0.3 ELSE 0 END,
      'weekly_bonus_dollars', ROUND(CASE et.role_level WHEN 'Unit Manager' THEN 0.001 WHEN 'Section Manager' THEN 0.002 WHEN 'Office Manager' THEN 0.003 ELSE 0 END * v_annual_ot_scorecard, 2),
      'annual_bonus_dollars', ROUND(CASE et.role_level WHEN 'Unit Manager' THEN 0.001 WHEN 'Section Manager' THEN 0.002 WHEN 'Office Manager' THEN 0.003 ELSE 0 END * v_annual_ot_scorecard * 52.0, 2)
    )), '[]'::jsonb)
  INTO v_annual_manager_bonus, v_manager_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  WHERE et.role_level IN ('Unit Manager','Section Manager','Office Manager');

  -- LIFE INSURANCE STIPEND (roster via canonical)
  SELECT
    COALESCE(SUM(m.monthly_cap * 12.0), 0),
    COALESCE(jsonb_agg(jsonb_build_object('team_member_id', et.team_id, 'name', et.first_name || ' ' || et.last_name, 'start_date', et.start_date, 'year_of_employment', m.yoe, 'monthly_cap_dollars', m.monthly_cap, 'annual_dollars', ROUND(m.monthly_cap * 12.0, 2))), '[]'::jsonb)
  INTO v_annual_life_ins, v_life_ins_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  CROSS JOIN LATERAL (SELECT GREATEST(1, FLOOR((p_week_end_date - et.start_date)::numeric / 365.25)::int + 1) AS yoe) yc
  CROSS JOIN LATERAL (SELECT yc.yoe, CASE WHEN yc.yoe = 1 THEN 50 WHEN yc.yoe = 2 THEN 100 WHEN yc.yoe = 3 THEN 150 WHEN yc.yoe = 4 THEN 200 WHEN yc.yoe = 5 THEN 250 WHEN yc.yoe = 6 THEN 300 WHEN yc.yoe = 7 THEN 350 WHEN yc.yoe = 8 THEN 400 WHEN yc.yoe = 9 THEN 450 WHEN yc.yoe = 10 THEN 475 ELSE 500 END AS monthly_cap) m
  WHERE et.start_date IS NOT NULL;

  -- APPAREL (roster via canonical)
  SELECT
    COALESCE(SUM(m.annual_apparel), 0),
    COALESCE(jsonb_agg(jsonb_build_object('team_member_id', et.team_id, 'name', et.first_name || ' ' || et.last_name, 'start_date', et.start_date, 'year_of_employment', m.yoe, 'annual_dollars', ROUND(m.annual_apparel, 2))), '[]'::jsonb)
  INTO v_annual_apparel, v_apparel_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  CROSS JOIN LATERAL (SELECT GREATEST(1, FLOOR((p_week_end_date - et.start_date)::numeric / 365.25)::int + 1) AS yoe) yc
  CROSS JOIN LATERAL (SELECT yc.yoe, CASE WHEN yc.yoe = 1 THEN 200 ELSE 100 END AS annual_apparel) m
  WHERE et.start_date IS NOT NULL;

  -- HEALTH DEVELOPMENT BONUS (roster via canonical)
  SELECT COALESCE(SUM(25 * 52.0), 0),
    COALESCE(jsonb_agg(jsonb_build_object('team_member_id', et.team_id, 'name', et.first_name || ' ' || et.last_name, 'weekly_max_dollars', 25, 'annual_max_dollars', 1300)), '[]'::jsonb)
  INTO v_annual_hdb, v_hdb_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et;

  v_annual_cc := v_cc_pct * v_annual_ot_basis;

  SELECT COALESCE(SUM(cs.reserve_amount), 0),
    COALESCE(jsonb_agg(jsonb_build_object('year', cs.year, 'reserve_amount', ROUND(cs.reserve_amount, 2), 'determined_at', cs.determined_at, 'notes', cs.notes)), '[]'::jsonb)
  INTO v_cc_reconciliation_credit, v_cc_reconciliation_detail
  FROM public.agency_cc_yearly_status cs
  WHERE cs.agency_id = p_agency_id AND cs.cc_hit = false AND cs.released_at IS NULL AND cs.reserve_amount IS NOT NULL;

  SELECT * INTO v_curr_cycle FROM public.current_cycle_info(p_agency_id, p_week_end_date);
  v_curr_cycle_start := v_curr_cycle.cycle_start;
  v_curr_cycle_end := v_curr_cycle.cycle_end;
  v_week_of_cycle := v_curr_cycle.week_of_cycle;
  v_prior_cycle_start := (v_curr_cycle_start - INTERVAL '91 days')::date;
  v_prior_cycle_end := (v_curr_cycle_start - INTERVAL '1 day')::date;

  SELECT COUNT(*) INTO v_curr_qtr_wins FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date >= v_curr_cycle_start AND week_ending_date <= LEAST(v_curr_cycle_end, p_week_end_date) AND won_the_week = true;

  SELECT COUNT(*) INTO v_prior_qtr_wins FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date >= v_prior_cycle_start AND week_ending_date <= v_prior_cycle_end AND won_the_week = true;

  v_annual_mvp := 0.01 * v_annual_ot_basis * (v_prior_qtr_wins::numeric / 13.0);
  v_max_possible_wins := v_curr_qtr_wins + GREATEST(0, 13 - v_week_of_cycle);
  IF v_max_possible_wins < 9 THEN
    v_annual_wtq := 0; v_wtq_halted := true;
    v_wtq_halt_reason := format('wins_to_date (%s) + weeks_remaining (%s) = %s < 9 floor', v_curr_qtr_wins, GREATEST(0, 13 - v_week_of_cycle), v_max_possible_wins);
  ELSE
    v_annual_wtq := 0.10 * v_annual_ot_basis * (v_curr_qtr_wins::numeric / 13.0);
  END IF;

  v_total_carveouts := v_annual_manager_bonus + v_annual_life_ins + v_annual_apparel + v_annual_hdb + v_annual_cc + v_annual_mvp + v_annual_wtq - v_cc_reconciliation_credit;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
    'inputs', jsonb_build_object('annual_ot_smvc', ROUND(v_annual_ot_smvc, 2), 'annual_ot_scorecard', ROUND(v_annual_ot_scorecard, 2), 'annual_ot_basis', ROUND(v_annual_ot_basis, 2), 'current_cycle_start', v_curr_cycle_start, 'current_cycle_end', v_curr_cycle_end, 'week_of_cycle', v_week_of_cycle, 'current_cycle_wins_to_date', v_curr_qtr_wins, 'max_possible_wins_this_cycle', v_max_possible_wins, 'prior_cycle_start', v_prior_cycle_start, 'prior_cycle_end', v_prior_cycle_end, 'prior_cycle_wins', v_prior_qtr_wins),
    'manager_bonus', jsonb_build_object('annual_dollars', ROUND(v_annual_manager_bonus, 2), 'weekly_dollars', ROUND(v_annual_manager_bonus / 52.0, 2), 'detail', v_manager_detail),
    'life_insurance_stipend', jsonb_build_object('annual_dollars', ROUND(v_annual_life_ins, 2), 'weekly_dollars', ROUND(v_annual_life_ins / 52.0, 2), 'formula', 'sum(monthly_cap_by_year_of_employment x 12) across active non-owner roster', 'detail', v_life_ins_detail),
    'apparel', jsonb_build_object('annual_dollars', ROUND(v_annual_apparel, 2), 'weekly_dollars', ROUND(v_annual_apparel / 52.0, 2), 'formula', 'Y1 = $200 (13-week + first anniversary), Y2+ = $100 (annual anniversary)', 'detail', v_apparel_detail),
    'health_development_bonus', jsonb_build_object('annual_dollars', ROUND(v_annual_hdb, 2), 'weekly_dollars', ROUND(v_annual_hdb / 52.0, 2), 'formula', '$25/week x 52 weeks per active non-owner team member (structural max)', 'detail', v_hdb_detail),
    'champions_circle', jsonb_build_object('annual_dollars', ROUND(v_annual_cc, 2), 'weekly_dollars', ROUND(v_annual_cc / 52.0, 2), 'pct_of_basis', v_cc_pct, 'formula', '3% x on-time (SMVC + Scorecard) annual basis, flat accrual', 'reconciliation_note', 'If CC not hit for a year, record cc_hit=false + reserve_amount in agency_cc_yearly_status. Reserve is credited back via cc_reconciliation_credit until released_at is set.'),
    'cc_reconciliation_credit', jsonb_build_object('annual_dollars', ROUND(v_cc_reconciliation_credit, 2), 'weekly_dollars', ROUND(v_cc_reconciliation_credit / 52.0, 2), 'note', 'Sum of prior-year CC reserves where cc_hit=false and released_at IS NULL. Reduces total carveouts (increases pool basis available for split).', 'detail', v_cc_reconciliation_detail),
    'mvp_prize_cart', jsonb_build_object('annual_dollars', ROUND(v_annual_mvp, 2), 'weekly_dollars', ROUND(v_annual_mvp / 52.0, 2), 'formula', '1% x annual OT (SMVC+Scorecard) x prior_qtr_wins/13', 'note', 'MVP prize cart restock funded from prior quarter wins'),
    'wtq_trip', jsonb_build_object('annual_dollars', ROUND(v_annual_wtq, 2), 'weekly_dollars', ROUND(v_annual_wtq / 52.0, 2), 'formula', '10% x annual OT (SMVC+Scorecard) x curr_qtr_wins/13', 'floor_wins', 9, 'halted', v_wtq_halted, 'halt_reason', v_wtq_halt_reason, 'note', 'Accrues weekly. Halts if math cannot reach 9-wins floor (dollars stay in pool).'),
    'total_annual_carveouts', ROUND(v_total_carveouts, 2),
    'total_weekly_carveouts', ROUND(v_total_carveouts / 52.0, 2),
    'computed_at', now()
  );
END;
$fn$;

