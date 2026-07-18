-- Goals uniform WtW shape: all 5 goals carveout buckets now use $10 x team_tenure_ramp_sum x 13 x 4.
-- Prior asymmetry (leaderboard by slots x cats, all-star by cats x tenure, trailblazer by cats x 1)
-- retired per Peter directive 2026-07-18.
--
-- Applied via Supabase MCP earlier this session; this file is the migration mirror per op-rule
-- "Newtworks commits — canonical path" > migration_mirror.

CREATE OR REPLACE FUNCTION public.compute_pool_carveouts(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_pool_result jsonb; v_annual_ot_smvc numeric; v_annual_ot_scorecard numeric; v_annual_ot_basis numeric;
  v_annual_manager_bonus numeric := 0; v_manager_detail jsonb := '[]'::jsonb;
  v_annual_life_ins numeric := 0; v_life_ins_detail jsonb := '[]'::jsonb;
  v_annual_apparel numeric := 0; v_apparel_detail jsonb := '[]'::jsonb;
  v_annual_hdb numeric := 0; v_hdb_detail jsonb := '[]'::jsonb;
  v_annual_cc numeric := 0; v_cc_pct CONSTANT numeric := 0.03;
  v_curr_cycle record; v_curr_cycle_start date; v_curr_cycle_end date; v_prior_cycle_start date; v_prior_cycle_end date;
  v_week_of_cycle int; v_curr_qtr_wins int := 0; v_prior_qtr_wins int := 0; v_weeks_remaining int; v_projected_wins int;
  v_rate CONSTANT numeric := 0.01; v_pace numeric := 0; v_pool_pace_dollars numeric := 0;
  v_quarterly_mvp numeric := 0; v_quarterly_wtq numeric := 0; v_wtq_halted boolean := false; v_wtq_halt_reason text := NULL;
  v_mvp_share_pct CONSTANT numeric := 0.50; v_rest_share_pct CONSTANT numeric := 0.50;
  v_team_count int := 0; v_team_tenure_ramp_sum numeric := 0; v_tenure_detail jsonb := '[]'::jsonb;
  v_rest_count int := 0; v_mvp_dollars numeric := 0; v_rest_pool_dollars numeric := 0; v_rest_per_person numeric := 0;
  v_leaderboard_categories CONSTANT int := 4; v_leaderboard_slots CONSTANT int := 3;
  v_annual_wtw_bonus numeric := 0; v_annual_gain_bonus numeric := 0; v_annual_leaderboard_bonus numeric := 0;
  v_annual_all_star_bonus numeric := 0; v_annual_trailblazer_bonus numeric := 0; v_annual_goals_total numeric := 0;
  v_total_carveouts_annual numeric;
BEGIN
  v_pool_result := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_annual_ot_smvc := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_smvc_dollars','')::numeric, 0);
  v_annual_ot_scorecard := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_scorecard_dollars','')::numeric, 0);
  v_annual_ot_basis := v_annual_ot_smvc + v_annual_ot_scorecard;

  SELECT COALESCE(SUM(CASE et.role_level WHEN 'Unit Manager' THEN 0.001 WHEN 'Section Manager' THEN 0.002 WHEN 'Office Manager' THEN 0.003 ELSE 0 END * 52.0 * v_annual_ot_scorecard), 0),
    COALESCE(jsonb_agg(jsonb_build_object('team_member_id', et.team_id, 'name', et.first_name || ' ' || et.last_name, 'role_level', et.role_level, 'weekly_rate_pct', CASE et.role_level WHEN 'Unit Manager' THEN 0.1 WHEN 'Section Manager' THEN 0.2 WHEN 'Office Manager' THEN 0.3 ELSE 0 END, 'weekly_bonus_dollars', ROUND(CASE et.role_level WHEN 'Unit Manager' THEN 0.001 WHEN 'Section Manager' THEN 0.002 WHEN 'Office Manager' THEN 0.003 ELSE 0 END * v_annual_ot_scorecard, 2), 'annual_bonus_dollars', ROUND(CASE et.role_level WHEN 'Unit Manager' THEN 0.001 WHEN 'Section Manager' THEN 0.002 WHEN 'Office Manager' THEN 0.003 ELSE 0 END * v_annual_ot_scorecard * 52.0, 2))), '[]'::jsonb)
  INTO v_annual_manager_bonus, v_manager_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  WHERE et.role_level IN ('Unit Manager','Section Manager','Office Manager');

  SELECT COALESCE(SUM(m.monthly_cap * 12.0), 0), COALESCE(jsonb_agg(jsonb_build_object('team_member_id', et.team_id, 'name', et.first_name || ' ' || et.last_name, 'start_date', et.start_date, 'year_of_employment', m.yoe, 'monthly_cap_dollars', m.monthly_cap, 'annual_dollars', ROUND(m.monthly_cap * 12.0, 2))), '[]'::jsonb)
  INTO v_annual_life_ins, v_life_ins_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  CROSS JOIN LATERAL (SELECT GREATEST(1, FLOOR((p_week_end_date - et.start_date)::numeric / 365.25)::int + 1) AS yoe) yc
  CROSS JOIN LATERAL (SELECT yc.yoe, CASE WHEN yc.yoe=1 THEN 50 WHEN yc.yoe=2 THEN 100 WHEN yc.yoe=3 THEN 150 WHEN yc.yoe=4 THEN 200 WHEN yc.yoe=5 THEN 250 WHEN yc.yoe=6 THEN 300 WHEN yc.yoe=7 THEN 350 WHEN yc.yoe=8 THEN 400 WHEN yc.yoe=9 THEN 450 WHEN yc.yoe=10 THEN 475 ELSE 500 END AS monthly_cap) m
  WHERE et.start_date IS NOT NULL;

  SELECT COALESCE(SUM(m.annual_apparel), 0), COALESCE(jsonb_agg(jsonb_build_object('team_member_id', et.team_id, 'name', et.first_name || ' ' || et.last_name, 'start_date', et.start_date, 'year_of_employment', m.yoe, 'annual_dollars', ROUND(m.annual_apparel, 2))), '[]'::jsonb)
  INTO v_annual_apparel, v_apparel_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  CROSS JOIN LATERAL (SELECT GREATEST(1, FLOOR((p_week_end_date - et.start_date)::numeric / 365.25)::int + 1) AS yoe) yc
  CROSS JOIN LATERAL (SELECT yc.yoe, CASE WHEN yc.yoe = 1 THEN 200 ELSE 100 END AS annual_apparel) m
  WHERE et.start_date IS NOT NULL;

  -- Team tenure ramp: 0.0 at hire → 1.0 at 52 weeks. Used to scale team-multiplied carveouts.
  SELECT
    COALESCE(SUM(LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - et.start_date)::numeric / 7.0) / 52.0))), 0),
    COALESCE(jsonb_agg(jsonb_build_object('team_member_id', et.team_id, 'name', et.first_name || ' ' || et.last_name, 'start_date', et.start_date, 'weeks_tenure', FLOOR((p_week_end_date - et.start_date)::numeric / 7.0)::int, 'tenure_ramp', ROUND(LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - et.start_date)::numeric / 7.0) / 52.0)), 4)) ORDER BY et.first_name), '[]'::jsonb)
  INTO v_team_tenure_ramp_sum, v_tenure_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  WHERE et.start_date IS NOT NULL;

  -- HDB: per-person $25/wk × 52 × own tenure_ramp
  SELECT
    COALESCE(SUM(25 * 52.0 * LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - et.start_date)::numeric / 7.0) / 52.0))), 0),
    COALESCE(jsonb_agg(jsonb_build_object('team_member_id', et.team_id, 'name', et.first_name || ' ' || et.last_name, 'tenure_ramp', ROUND(LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - et.start_date)::numeric / 7.0) / 52.0)), 4), 'weekly_max_dollars', 25, 'weekly_max_at_full_tenure', 25, 'weekly_ramped', ROUND(25 * LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - et.start_date)::numeric / 7.0) / 52.0)), 2), 'annual_ramped', ROUND(25 * 52 * LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - et.start_date)::numeric / 7.0) / 52.0)), 2)) ORDER BY et.first_name), '[]'::jsonb)
  INTO v_annual_hdb, v_hdb_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  WHERE et.start_date IS NOT NULL;

  v_annual_cc := v_cc_pct * v_annual_ot_basis;

  SELECT * INTO v_curr_cycle FROM public.current_cycle_info(p_agency_id, p_week_end_date);
  v_curr_cycle_start := v_curr_cycle.cycle_start; v_curr_cycle_end := v_curr_cycle.cycle_end; v_week_of_cycle := v_curr_cycle.week_of_cycle;
  v_prior_cycle_start := (v_curr_cycle_start - INTERVAL '91 days')::date;
  v_prior_cycle_end := (v_curr_cycle_start - INTERVAL '1 day')::date;
  SELECT COUNT(*) INTO v_curr_qtr_wins FROM public.weekly_cpr_reports WHERE agency_id = p_agency_id AND week_ending_date >= v_curr_cycle_start AND week_ending_date <= LEAST(v_curr_cycle_end, p_week_end_date) AND won_the_week = true;
  SELECT COUNT(*) INTO v_prior_qtr_wins FROM public.weekly_cpr_reports WHERE agency_id = p_agency_id AND week_ending_date >= v_prior_cycle_start AND week_ending_date <= v_prior_cycle_end AND won_the_week = true;
  v_weeks_remaining := GREATEST(0, 13 - v_week_of_cycle);
  v_projected_wins := v_curr_qtr_wins + v_weeks_remaining;
  v_pace := LEAST(1.0, v_projected_wins::numeric / 13.0);
  v_pool_pace_dollars := v_rate * v_annual_ot_basis * v_pace;
  IF v_projected_wins < 9 THEN v_quarterly_wtq := 0; v_wtq_halted := true; v_wtq_halt_reason := format('projected_wins (%s) < 9 floor.', v_projected_wins);
  ELSE v_quarterly_wtq := v_pool_pace_dollars; END IF;
  v_quarterly_mvp := v_pool_pace_dollars;

  SELECT COUNT(*) INTO v_team_count FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date);
  v_rest_count := GREATEST(0, v_team_count - 1);
  v_mvp_dollars := v_quarterly_wtq * v_mvp_share_pct;
  v_rest_pool_dollars := v_quarterly_wtq * v_rest_share_pct;
  v_rest_per_person := CASE WHEN v_rest_count > 0 THEN v_rest_pool_dollars / v_rest_count::numeric ELSE 0 END;

  -- Rev 2026-07-18 (Peter directive): all 5 goals buckets now use uniform WtW formula.
  -- $10 × team_tenure_ramp_sum × 13 × 4 per bucket, scales with each teammate's 0.0→1.0 tenure ramp.
  -- Prior asymmetry (leaderboard by slots×cats, all-star by cats×tenure, trailblazer by cats×1) retired.
  v_annual_wtw_bonus         := 10 * v_team_tenure_ramp_sum * 13 * 4;
  v_annual_gain_bonus        := 10 * v_team_tenure_ramp_sum * 13 * 4;
  v_annual_leaderboard_bonus := 10 * v_team_tenure_ramp_sum * 13 * 4;
  v_annual_all_star_bonus    := 10 * v_team_tenure_ramp_sum * 13 * 4;
  v_annual_trailblazer_bonus := 10 * v_team_tenure_ramp_sum * 13 * 4;
  v_annual_goals_total := v_annual_wtw_bonus + v_annual_gain_bonus + v_annual_leaderboard_bonus + v_annual_all_star_bonus + v_annual_trailblazer_bonus;

  v_total_carveouts_annual := v_annual_manager_bonus + v_annual_life_ins + v_annual_apparel + v_annual_hdb + v_annual_cc + (v_quarterly_mvp * 4.0) + (v_quarterly_wtq * 4.0) + v_annual_goals_total;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
    'design_note', 'Carve-and-forget. All 5 goals buckets (WtW, Gain, Leaderboard, All-Star, Trailblazer) now share the WtW formula: $10 × team_tenure_ramp_sum × 13 × 4. Each scales with per-person tenure ramp (0.0→1.0 over first 52 weeks). Rev 2026-07-18.',
    'inputs', jsonb_build_object('annual_ot_smvc', ROUND(v_annual_ot_smvc, 2), 'annual_ot_scorecard', ROUND(v_annual_ot_scorecard, 2), 'annual_ot_basis', ROUND(v_annual_ot_basis, 2), 'team_count', v_team_count, 'team_tenure_ramp_sum', ROUND(v_team_tenure_ramp_sum, 4), 'tenure_detail', v_tenure_detail, 'leaderboard_categories', v_leaderboard_categories, 'leaderboard_slots', v_leaderboard_slots, 'current_cycle_start', v_curr_cycle_start, 'current_cycle_end', v_curr_cycle_end, 'week_of_cycle', v_week_of_cycle, 'current_cycle_wins_to_date', v_curr_qtr_wins, 'weeks_remaining', v_weeks_remaining, 'projected_wins', v_projected_wins, 'on_time_pace', ROUND(v_pace, 4)),
    'manager_bonus', jsonb_build_object('annual_dollars', ROUND(v_annual_manager_bonus, 2), 'weekly_dollars', ROUND(v_annual_manager_bonus / 52.0, 2), 'formula', 'sum(role_level_pct × on-time Scorecard annual)', 'detail', v_manager_detail),
    'life_insurance_stipend', jsonb_build_object('annual_dollars', ROUND(v_annual_life_ins, 2), 'weekly_dollars', ROUND(v_annual_life_ins / 52.0, 2), 'formula', 'sum(monthly_cap_by_year_of_employment × 12)', 'detail', v_life_ins_detail),
    'apparel', jsonb_build_object('annual_dollars', ROUND(v_annual_apparel, 2), 'weekly_dollars', ROUND(v_annual_apparel / 52.0, 2), 'formula', 'Y1 = $200, Y2+ = $100', 'detail', v_apparel_detail),
    'health_development_bonus', jsonb_build_object('annual_dollars', ROUND(v_annual_hdb, 2), 'weekly_dollars', ROUND(v_annual_hdb / 52.0, 2), 'formula', 'per-person $25/wk × 52 × tenure_ramp (structural max, carve-and-forget)', 'detail', v_hdb_detail),
    'champions_circle', jsonb_build_object('annual_dollars', ROUND(v_annual_cc, 2), 'weekly_dollars', ROUND(v_annual_cc / 52.0, 2), 'pct_of_basis', v_cc_pct, 'formula', '3% × on-time (SMVC + Scorecard) annual'),
    'mvp_prize_cart', jsonb_build_object('quarterly_dollars', ROUND(v_quarterly_mvp, 2), 'annual_dollars', ROUND(v_quarterly_mvp * 4.0, 2), 'weekly_dollars', ROUND(v_quarterly_mvp / 13.0, 2), 'formula', '1% × on-time (SMVC + Scorecard) × pace, QUARTERLY pot', 'rate_pct', v_rate, 'pace', ROUND(v_pace, 4), 'projected_wins', v_projected_wins),
    'wtq_trip', jsonb_build_object('quarterly_dollars', ROUND(v_quarterly_wtq, 2), 'annual_dollars', ROUND(v_quarterly_wtq * 4.0, 2), 'weekly_dollars', ROUND(v_quarterly_wtq / 13.0, 2), 'formula', '1% × on-time (SMVC + Scorecard) × pace, QUARTERLY pot', 'rate_pct', v_rate, 'pace', ROUND(v_pace, 4), 'projected_wins', v_projected_wins, 'floor_wins', 9, 'halted', v_wtq_halted, 'halt_reason', v_wtq_halt_reason, 'mvp_share_pct', v_mvp_share_pct, 'rest_share_pct', v_rest_share_pct, 'team_count', v_team_count, 'rest_of_team_count', v_rest_count, 'mvp_dollars', ROUND(v_mvp_dollars, 2), 'rest_pool_dollars', ROUND(v_rest_pool_dollars, 2), 'rest_per_person_dollars', ROUND(v_rest_per_person, 2)),
    'wtw_bonus', jsonb_build_object('annual_dollars', ROUND(v_annual_wtw_bonus, 2), 'quarterly_dollars', ROUND(v_annual_wtw_bonus / 4.0, 2), 'weekly_dollars', ROUND(v_annual_wtw_bonus / 52.0, 2), 'per_hit_dollars', 10, 'formula', '$10 × team_tenure_ramp_sum × 13 × 4 (carve-and-forget)'),
    'gain_bonus', jsonb_build_object('annual_dollars', ROUND(v_annual_gain_bonus, 2), 'quarterly_dollars', ROUND(v_annual_gain_bonus / 4.0, 2), 'weekly_dollars', ROUND(v_annual_gain_bonus / 52.0, 2), 'per_hit_dollars', 10, 'formula', '$10 × team_tenure_ramp_sum × 13 × 4 (carve-and-forget)'),
    'leaderboard_bonus', jsonb_build_object('annual_dollars', ROUND(v_annual_leaderboard_bonus, 2), 'quarterly_dollars', ROUND(v_annual_leaderboard_bonus / 4.0, 2), 'weekly_dollars', ROUND(v_annual_leaderboard_bonus / 52.0, 2), 'per_hit_dollars', 10, 'formula', '$10 × team_tenure_ramp_sum × 13 × 4 (carve-and-forget, uniform WtW shape)'),
    'all_star_bonus', jsonb_build_object('annual_dollars', ROUND(v_annual_all_star_bonus, 2), 'quarterly_dollars', ROUND(v_annual_all_star_bonus / 4.0, 2), 'weekly_dollars', ROUND(v_annual_all_star_bonus / 52.0, 2), 'per_hit_dollars', 10, 'formula', '$10 × team_tenure_ramp_sum × 13 × 4 (carve-and-forget, uniform WtW shape)'),
    'trailblazer_bonus', jsonb_build_object('annual_dollars', ROUND(v_annual_trailblazer_bonus, 2), 'quarterly_dollars', ROUND(v_annual_trailblazer_bonus / 4.0, 2), 'weekly_dollars', ROUND(v_annual_trailblazer_bonus / 52.0, 2), 'per_hit_dollars', 10, 'formula', '$10 × team_tenure_ramp_sum × 13 × 4 (carve-and-forget, uniform WtW shape)'),
    'goals_bonus_total', jsonb_build_object('annual_dollars', ROUND(v_annual_goals_total, 2), 'quarterly_dollars', ROUND(v_annual_goals_total / 4.0, 2), 'weekly_dollars', ROUND(v_annual_goals_total / 52.0, 2)),
    'total_annual_carveouts', ROUND(v_total_carveouts_annual, 2), 'total_weekly_carveouts', ROUND(v_total_carveouts_annual / 52.0, 2),
    'computed_at', now()
  );
END;
$function$
