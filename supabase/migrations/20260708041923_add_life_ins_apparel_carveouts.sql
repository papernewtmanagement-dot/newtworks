-- Migration: add_life_ins_apparel_carveouts
-- Adds Life Insurance Stipend + Apparel to compute_pool_carveouts() as new pre-pool carve-outs.
-- Companion handbook edits: manuals row 3482bf9c-25ff-... 'Getting Paid' restructured (Parts 5/6/7 renumbered);
-- referral bonus moved to new 'Team Growth' handbook page (sort_order 45).
-- Applied via Supabase MCP 2026-07-08.

CREATE OR REPLACE FUNCTION public.compute_pool_carveouts(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
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
  -- Read pool basis
  v_pool_result         := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_annual_ot_smvc      := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_smvc_dollars','')::numeric, 0);
  v_annual_ot_scorecard := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_scorecard_dollars','')::numeric, 0);
  v_annual_ot_basis     := v_annual_ot_smvc + v_annual_ot_scorecard;

  -- MANAGER BONUS
  -- Weekly: 0.1/0.2/0.3% x annual OT Scorecard per manager
  -- Annual: x 52 for annualized carve-out
  SELECT
    COALESCE(SUM(
      CASE t.role_level
        WHEN 'Unit Manager'    THEN 0.001
        WHEN 'Section Manager' THEN 0.002
        WHEN 'Office Manager'  THEN 0.003
        ELSE 0
      END * 52.0 * v_annual_ot_scorecard
    ), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', t.id,
      'name', t.first_name || ' ' || t.last_name,
      'role_level', t.role_level,
      'weekly_rate_pct', CASE t.role_level
                          WHEN 'Unit Manager'    THEN 0.1
                          WHEN 'Section Manager' THEN 0.2
                          WHEN 'Office Manager'  THEN 0.3
                          ELSE 0 END,
      'weekly_bonus_dollars', ROUND(
        CASE t.role_level
          WHEN 'Unit Manager'    THEN 0.001
          WHEN 'Section Manager' THEN 0.002
          WHEN 'Office Manager'  THEN 0.003
          ELSE 0 END * v_annual_ot_scorecard, 2),
      'annual_bonus_dollars', ROUND(
        CASE t.role_level
          WHEN 'Unit Manager'    THEN 0.001
          WHEN 'Section Manager' THEN 0.002
          WHEN 'Office Manager'  THEN 0.003
          ELSE 0 END * v_annual_ot_scorecard * 52.0, 2)
    )), '[]'::jsonb)
  INTO v_annual_manager_bonus, v_manager_detail
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND t.is_active = true
    AND t.archived_at IS NULL
    AND t.is_admin_backoffice = false
    AND t.role_level IN ('Unit Manager','Section Manager','Office Manager');

  -- LIFE INSURANCE STIPEND CARVE-OUT
  -- Every active non-owner, non-admin team member with a start_date.
  -- Monthly cap by year of employment (Y1..Y10+), from handbook Part 5.
  -- Annualized = monthly_cap * 12.
  SELECT
    COALESCE(SUM(m.monthly_cap * 12.0), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id',   t.id,
      'name',             t.first_name || ' ' || t.last_name,
      'start_date',       t.start_date,
      'year_of_employment', m.yoe,
      'monthly_cap_dollars', m.monthly_cap,
      'annual_dollars',    ROUND(m.monthly_cap * 12.0, 2)
    )), '[]'::jsonb)
  INTO v_annual_life_ins, v_life_ins_detail
  FROM public.team t
  CROSS JOIN LATERAL (
    SELECT
      GREATEST(1, FLOOR((p_week_end_date - t.start_date)::numeric / 365.25)::int + 1) AS yoe
  ) yc
  CROSS JOIN LATERAL (
    SELECT
      yc.yoe,
      CASE
        WHEN yc.yoe = 1  THEN 50
        WHEN yc.yoe = 2  THEN 100
        WHEN yc.yoe = 3  THEN 150
        WHEN yc.yoe = 4  THEN 200
        WHEN yc.yoe = 5  THEN 250
        WHEN yc.yoe = 6  THEN 300
        WHEN yc.yoe = 7  THEN 350
        WHEN yc.yoe = 8  THEN 400
        WHEN yc.yoe = 9  THEN 450
        WHEN yc.yoe = 10 THEN 475
        ELSE 500
      END AS monthly_cap
  ) m
  WHERE t.agency_id = p_agency_id
    AND t.is_active = true
    AND t.archived_at IS NULL
    AND t.is_admin_backoffice = false
    AND t.category = 'agency'
    AND COALESCE(t.role_level, '') <> 'Owner'
    AND t.start_date IS NOT NULL;

  -- APPAREL CARVE-OUT
  -- Every active non-owner, non-admin team member gets $100 per anniversary.
  -- In year 1 they ALSO get $100 for completing the 13-week onboarding.
  -- Simplified annualized: Y1 = $200, Y2+ = $100.
  SELECT
    COALESCE(SUM(m.annual_apparel), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id',   t.id,
      'name',             t.first_name || ' ' || t.last_name,
      'start_date',       t.start_date,
      'year_of_employment', m.yoe,
      'annual_dollars',    ROUND(m.annual_apparel, 2)
    )), '[]'::jsonb)
  INTO v_annual_apparel, v_apparel_detail
  FROM public.team t
  CROSS JOIN LATERAL (
    SELECT
      GREATEST(1, FLOOR((p_week_end_date - t.start_date)::numeric / 365.25)::int + 1) AS yoe
  ) yc
  CROSS JOIN LATERAL (
    SELECT
      yc.yoe,
      CASE WHEN yc.yoe = 1 THEN 200 ELSE 100 END AS annual_apparel
  ) m
  WHERE t.agency_id = p_agency_id
    AND t.is_active = true
    AND t.archived_at IS NULL
    AND t.is_admin_backoffice = false
    AND t.category = 'agency'
    AND COALESCE(t.role_level, '') <> 'Owner'
    AND t.start_date IS NOT NULL;

  -- Cycle bounds via canonical helper
  SELECT * INTO v_curr_cycle FROM public.current_cycle_info(p_agency_id, p_week_end_date);
  v_curr_cycle_start  := v_curr_cycle.cycle_start;
  v_curr_cycle_end    := v_curr_cycle.cycle_end;
  v_week_of_cycle     := v_curr_cycle.week_of_cycle;
  v_prior_cycle_start := (v_curr_cycle_start - INTERVAL '91 days')::date;
  v_prior_cycle_end   := (v_curr_cycle_start - INTERVAL '1 day')::date;

  -- Wins to date this cycle
  SELECT COUNT(*) INTO v_curr_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date >= v_curr_cycle_start
    AND week_ending_date <= LEAST(v_curr_cycle_end, p_week_end_date)
    AND won_the_week = true;

  -- Wins in prior cycle
  SELECT COUNT(*) INTO v_prior_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date >= v_prior_cycle_start
    AND week_ending_date <= v_prior_cycle_end
    AND won_the_week = true;

  -- MVP PRIZE CART (annualized)
  -- Quarterly: 1% x (Q_OT_SMVC + Q_OT_Scorecard) x prior_qtr_wins/13
  -- Annualized (x 4 quarters, quarterly basis is annual/4): 1% x annual_basis x prior_wins/13
  v_annual_mvp := 0.01 * v_annual_ot_basis * (v_prior_qtr_wins::numeric / 13.0);

  -- WtQ TRIP (annualized) with floor-impossible halt
  -- Formula: 10% x annual_ot_basis x curr_qtr_wins/13
  -- Floor: if math can't reach 9/13 wins by end of quarter, halt accrual (dollars return to pool)
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
                    + v_annual_mvp
                    + v_annual_wtq;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'week_end_date', p_week_end_date,
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
      'detail',         v_manager_detail
    ),
    'life_insurance_stipend', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_life_ins, 2),
      'weekly_dollars', ROUND(v_annual_life_ins / 52.0, 2),
      'formula',        'sum(monthly_cap_by_year_of_employment x 12) across active non-owner roster',
      'detail',         v_life_ins_detail
    ),
    'apparel', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_apparel, 2),
      'weekly_dollars', ROUND(v_annual_apparel / 52.0, 2),
      'formula',        'Y1 = $200 (13-week + first anniversary), Y2+ = $100 (annual anniversary)',
      'detail',         v_apparel_detail
    ),
    'mvp_prize_cart', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_mvp, 2),
      'weekly_dollars', ROUND(v_annual_mvp / 52.0, 2),
      'formula',        '1% x annual OT (SMVC+Scorecard) x prior_qtr_wins/13',
      'note',           'MVP prize cart restock funded from prior quarter wins'
    ),
    'wtq_trip', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_wtq, 2),
      'weekly_dollars', ROUND(v_annual_wtq / 52.0, 2),
      'formula',        '10% x annual OT (SMVC+Scorecard) x curr_qtr_wins/13',
      'floor_wins',     9,
      'halted',         v_wtq_halted,
      'halt_reason',    v_wtq_halt_reason,
      'note',           'Accrues weekly. Halts if math cannot reach 9-wins floor (dollars stay in pool).'
    ),
    'total_annual_carveouts', ROUND(v_total_carveouts, 2),
    'total_weekly_carveouts', ROUND(v_total_carveouts / 52.0, 2),
    'computed_at', now()
  );
END;
$function$;
