CREATE OR REPLACE FUNCTION public.recompute_cpr_outcome(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_cycle record;
  v_week_start date;
  v_targets record;
  v_carryover int := 0;
  v_net_quotes numeric := 0;
  v_quotes_pool int := 0;
  v_step1_total int := 0;
  v_qtd_sp numeric := 0;
  v_sp_target numeric;
  v_won boolean;
  v_raw_pass boolean;
  v_sp_pass boolean;
  v_eligible boolean;
  v_step2_total int;
  v_effective_net numeric;
  v_quotes_pass boolean;
  v_owed_next int;
  v_restored_total int;
  v_pay_write jsonb;
  v_totals record;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'not authorized: recomputing the weekly outcome is owner or manager only';
  END IF;
  v_week_start := p_week_end_date - 6;
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_week_end_date);

  SELECT * INTO v_targets FROM public.compute_wtw_week_targets(p_agency_id, v_week_start);

  -- get_weekly_cpr_requirements' net_quotes already includes the individual WtW requirements
  -- buy-back (locked 2026-08-15) — it's the single canonical source now, so no separate pass is
  -- needed to fold that part in. buyback is also summed here (v_step1_total) purely for the
  -- transparency field wtw_quotes_restored below.
  SELECT COALESCE(SUM(net_quotes),0),
         COALESCE(SUM(quotes_discussed),0)::int,
         COALESCE(SUM(buyback),0)::int
    INTO v_net_quotes, v_quotes_pool, v_step1_total
  FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_end_date);

  IF v_cycle.week_of_cycle <= 1 THEN
    v_carryover := 0;
  ELSE
    SELECT COALESCE(quotes_owed_next_week,0) INTO v_carryover
    FROM public.weekly_cpr_reports
    WHERE agency_id=p_agency_id AND week_ending_date=v_cycle.prior_week_ending_saturday;
    v_carryover := COALESCE(v_carryover,0);
  END IF;

  v_sp_target := public.compute_cumulative_sp_target(p_agency_id, v_cycle.week_of_cycle, v_cycle.cycle_start);

  -- Single shared calculation (get_team_checkin_totals) — fixed 2026-08-12, see function comment.
  SELECT * INTO v_totals FROM public.get_team_checkin_totals(p_agency_id, v_cycle.cycle_start, p_week_end_date);
  v_qtd_sp := v_totals.total_sales_points;

  v_sp_pass  := v_qtd_sp >= v_sp_target;
  v_raw_pass := v_quotes_pool >= (v_targets.quotes_fresh_needed + v_carryover);
  v_eligible := v_raw_pass AND v_sp_pass;

  -- Step 2 (team-pool remainder, locked 2026-08-15): whatever gap remains after individual
  -- buy-backs (already folded into v_net_quotes) is regained from the shared bonus pool — only
  -- when the team was genuinely on track to win (enough raw quotes AND sales points) before
  -- requirements touched anything. Mirrors the gate inside get_weekly_cpr_requirements.
  v_step2_total := CASE WHEN v_eligible THEN GREATEST(0, v_targets.quotes_fresh_needed + v_carryover - v_net_quotes) ELSE 0 END;
  v_effective_net := v_net_quotes + v_step2_total;
  v_restored_total := v_step1_total + v_step2_total;

  v_quotes_pass := v_effective_net >= (v_targets.quotes_fresh_needed + v_carryover);
  v_won := v_quotes_pass AND v_sp_pass;
  v_owed_next := GREATEST(0, v_targets.quotes_fresh_needed + v_carryover - v_effective_net);

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, sales_points_target_this_week,
    quarterly_sales_points_qtd, won_the_week, wtw_quotes_restored,
    created_at, updated_at
  )
  VALUES (
    p_agency_id, p_week_end_date,
    v_carryover, v_targets.quotes_fresh_needed, v_net_quotes, v_owed_next,
    v_sp_target, v_targets.this_week_sp_increment,
    v_qtd_sp, v_won, v_restored_total,
    now(), now()
  )
  ON CONFLICT (agency_id, week_ending_date) DO UPDATE SET
    quotes_owed_carryover = EXCLUDED.quotes_owed_carryover,
    quotes_fresh_needed = EXCLUDED.quotes_fresh_needed,
    quotes_total_net = EXCLUDED.quotes_total_net,
    quotes_owed_next_week = EXCLUDED.quotes_owed_next_week,
    quarterly_sales_points_target = EXCLUDED.quarterly_sales_points_target,
    sales_points_target_this_week = EXCLUDED.sales_points_target_this_week,
    quarterly_sales_points_qtd = EXCLUDED.quarterly_sales_points_qtd,
    won_the_week = EXCLUDED.won_the_week,
    wtw_quotes_restored = EXCLUDED.wtw_quotes_restored,
    updated_at = now();

  v_pay_write := public.write_weekly_comp_v2(p_agency_id, p_week_end_date);

  RETURN jsonb_build_object(
    'week_ending', p_week_end_date,
    'week_of_cycle', v_cycle.week_of_cycle,
    'carryover', v_carryover,
    'fresh_needed', v_targets.quotes_fresh_needed,
    'net_quotes', v_net_quotes,
    'quotes_restored', v_restored_total,
    'effective_net_quotes', v_effective_net,
    'quotes_pool', v_quotes_pool,
    'owed_next', v_owed_next,
    'sp_qtd', v_qtd_sp,
    'sp_target', v_sp_target,
    'quotes_pass', v_quotes_pass,
    'sp_pass', v_sp_pass,
    'won_the_week', v_won,
    'wtw_requirements_adjustment', v_pay_write->'wtw_requirements_adjustment',
    'payroll_rows', v_pay_write->>'rows_updated',
    'mvp_detected', COALESCE(v_pay_write->'mvp_detection_result'->>'detected','false')
  );
END;
$function$;
