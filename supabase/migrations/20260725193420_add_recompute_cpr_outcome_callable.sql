-- Callable outcome writer that takes an explicit week_end_date.
-- Mirrors the compute logic in weekly_cpr_compute_outcome (cron entry point)
-- but is safe to invoke on-demand from the CPR page Save handler + page load.
-- Frontend CPRDetail.jsx now calls this instead of write_weekly_comp_v2 on both
-- Save and page load, so the MVP banner + won_the_week track live truth.
-- weekly_cpr_compute_outcome retains its own compute logic for the cron path;
-- keeping the two in lockstep is manual until a future refactor collapses them.

CREATE OR REPLACE FUNCTION public.recompute_cpr_outcome(
  p_agency_id uuid,
  p_week_end_date date
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions'
AS $fn$
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
BEGIN
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

  SELECT COALESCE(SUM(latest_sp),0) INTO v_qtd_sp FROM (
    SELECT DISTINCT ON (tc.team_id) tc.sales_points_quarter AS latest_sp
    FROM public.team_checkins tc
    WHERE tc.agency_id=p_agency_id
      AND tc.checkin_date BETWEEN v_cycle.cycle_start AND p_week_end_date
      AND tc.checkin_type IN ('midday','eod')
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ) per_member;

  v_quotes_pass := v_net_quotes >= (v_targets.quotes_fresh_needed + v_carryover);
  v_sp_pass := v_qtd_sp >= v_sp_target;
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

  RETURN jsonb_build_object(
    'week_ending', p_week_end_date,
    'week_of_cycle', v_cycle.week_of_cycle,
    'carryover', v_carryover,
    'fresh_needed', v_targets.quotes_fresh_needed,
    'net_quotes', v_net_quotes,
    'quotes_pool', v_quotes_pool,
    'owed_next', v_owed_next,
    'sp_qtd', v_qtd_sp,
    'sp_target', v_sp_target,
    'quotes_pass', v_quotes_pass,
    'sp_pass', v_sp_pass,
    'won_the_week', v_won,
    'payroll_rows', v_pay_write->>'rows_updated',
    'mvp_detected', COALESCE(v_pay_write->'mvp_detection_result'->>'detected','false')
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.recompute_cpr_outcome(uuid, date) TO authenticated, service_role;
