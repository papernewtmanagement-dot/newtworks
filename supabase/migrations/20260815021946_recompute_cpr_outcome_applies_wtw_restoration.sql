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
  v_net_quotes int := 0;
  v_quotes_pool int := 0;
  v_qtd_sp numeric := 0;
  v_sp_target numeric;
  v_won boolean;
  v_quotes_pass boolean;
  v_sp_pass boolean;
  v_owed_next int;
  v_pay_write jsonb;
  v_totals record;
  v_restored_total int := 0;
  v_effective_net int;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'not authorized: recomputing the weekly outcome is owner or manager only';
  END IF;
  v_week_start := p_week_end_date - 6;
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_week_end_date);

  SELECT * INTO v_targets FROM public.compute_wtw_week_targets(p_agency_id, v_week_start);

  SELECT COALESCE(SUM(net_quotes),0)::int,
         COALESCE(SUM(quotes_discussed),0)::int
    INTO v_net_quotes, v_quotes_pool
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

  v_sp_pass := v_qtd_sp >= v_sp_target;

  -- Pass 1 (provisional): write raw-numbers state so write_weekly_comp_v2 below has fresh_needed
  -- / carryover / SP columns to read when it computes the WtW requirements buy-back.
  v_quotes_pass := v_net_quotes >= (v_targets.quotes_fresh_needed + v_carryover);
  v_won := v_quotes_pass AND v_sp_pass;
  v_owed_next := GREATEST(0, v_targets.quotes_fresh_needed + v_carryover - v_net_quotes);

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, sales_points_target_this_week,
    quarterly_sales_points_qtd, won_the_week,
    created_at, updated_at
  )
  VALUES (
    p_agency_id, p_week_end_date,
    v_carryover, v_targets.quotes_fresh_needed, v_net_quotes, v_owed_next,
    v_sp_target, v_targets.this_week_sp_increment,
    v_qtd_sp, v_won,
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
    updated_at = now();

  v_pay_write := public.write_weekly_comp_v2(p_agency_id, p_week_end_date);

  -- Pass 2 (locked 2026-08-15): write_weekly_comp_v2 just ran the WtW requirements buy-back
  -- (compute_wtw_requirements_adjustment). Fold whatever quotes it restored back into net_quotes
  -- for the actual win/lose call and next week's carryover — this is what makes paying the $10/
  -- quote buy-back actually restore the team's shot at winning the week, not just cost money.
  v_restored_total := COALESCE((v_pay_write->'wtw_requirements_adjustment'->>'restored_total')::int, 0);
  v_effective_net := v_net_quotes + v_restored_total;
  v_quotes_pass := v_effective_net >= (v_targets.quotes_fresh_needed + v_carryover);
  v_won := v_quotes_pass AND v_sp_pass;
  v_owed_next := GREATEST(0, v_targets.quotes_fresh_needed + v_carryover - v_effective_net);

  UPDATE public.weekly_cpr_reports
  SET won_the_week = v_won,
      quotes_owed_next_week = v_owed_next,
      wtw_quotes_restored = v_restored_total,
      updated_at = now()
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

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
