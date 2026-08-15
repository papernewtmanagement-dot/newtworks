CREATE OR REPLACE FUNCTION public.weekly_cpr_compute_outcome(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_input_config jsonb;
  v_local_time text;
  v_today date;
  v_cycle record;
  v_week_start date;
  v_week_end date;
  v_targets record;
  v_quotes_fresh_needed int;
  v_team_carryover int := 0;
  v_team_net_quotes numeric := 0;
  v_team_quotes_pool int := 0;
  v_step1_total int := 0;
  v_sales_points_qtd numeric := 0;
  v_this_week_sp_increment numeric;
  v_sp_target numeric;
  v_won boolean;
  v_raw_pass boolean;
  v_sp_pass boolean;
  v_eligible boolean;
  v_step2_total int;
  v_effective_net numeric;
  v_quotes_pass boolean;
  v_quotes_owed_next int := 0;
  v_restored_total int;
  v_result_id uuid;
  v_pay_write jsonb;
  v_totals record;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_local_time := v_input_config->>'local_time';

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, v_today);
  v_week_end := v_cycle.week_ending_saturday;
  v_week_start := v_week_end - 6;

  SELECT * INTO v_targets FROM public.compute_wtw_week_targets(p_agency_id, v_week_start);
  v_quotes_fresh_needed := v_targets.quotes_fresh_needed;
  v_this_week_sp_increment := v_targets.this_week_sp_increment;

  -- get_weekly_cpr_requirements' net_quotes already includes the individual WtW requirements
  -- buy-back (locked 2026-08-15) — the single canonical source, no separate pass needed.
  SELECT
    COALESCE(SUM(net_quotes),       0),
    COALESCE(SUM(quotes_discussed), 0)::int,
    COALESCE(SUM(buyback),          0)::int
  INTO
    v_team_net_quotes, v_team_quotes_pool, v_step1_total
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);

  IF v_cycle.week_of_cycle <= 1 THEN
    v_team_carryover := 0;
  ELSE
    SELECT COALESCE(quotes_owed_next_week, 0) INTO v_team_carryover
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id
      AND week_ending_date = v_cycle.prior_week_ending_saturday;
    v_team_carryover := COALESCE(v_team_carryover, 0);
  END IF;

  v_sp_target := public.compute_cumulative_sp_target(p_agency_id, v_cycle.week_of_cycle, v_cycle.cycle_start);

  -- Single shared calculation (get_team_checkin_totals) — fixed 2026-08-12, see function comment.
  SELECT * INTO v_totals FROM public.get_team_checkin_totals(p_agency_id, v_cycle.cycle_start, v_week_end);
  v_sales_points_qtd := v_totals.total_sales_points;

  v_sp_pass  := v_sales_points_qtd >= v_sp_target;
  v_raw_pass := v_team_quotes_pool >= (v_quotes_fresh_needed + v_team_carryover);
  v_eligible := v_raw_pass AND v_sp_pass;

  -- Step 2 (team-pool remainder, locked 2026-08-15) — see recompute_cpr_outcome for the twin of
  -- this logic and the full rationale.
  v_step2_total := CASE WHEN v_eligible THEN GREATEST(0, v_quotes_fresh_needed + v_team_carryover - v_team_net_quotes) ELSE 0 END;
  v_effective_net := v_team_net_quotes + v_step2_total;
  v_restored_total := v_step1_total + v_step2_total;

  v_quotes_pass := v_effective_net >= (v_quotes_fresh_needed + v_team_carryover);
  v_won := v_quotes_pass AND v_sp_pass;
  v_quotes_owed_next := GREATEST(0, v_quotes_fresh_needed + v_team_carryover - v_effective_net);

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, sales_points_target_this_week,
    quarterly_sales_points_qtd, won_the_week, wtw_quotes_restored,
    created_at, updated_at
  )
  VALUES (
    p_agency_id, v_week_end,
    v_team_carryover, v_quotes_fresh_needed, v_team_net_quotes, v_quotes_owed_next,
    v_sp_target, v_this_week_sp_increment,
    v_sales_points_qtd, v_won, v_restored_total,
    now(), now()
  )
  ON CONFLICT (agency_id, week_ending_date) DO UPDATE
    SET quotes_owed_carryover = EXCLUDED.quotes_owed_carryover,
        quotes_fresh_needed = EXCLUDED.quotes_fresh_needed,
        quotes_total_net = EXCLUDED.quotes_total_net,
        quotes_owed_next_week = EXCLUDED.quotes_owed_next_week,
        quarterly_sales_points_target = EXCLUDED.quarterly_sales_points_target,
        sales_points_target_this_week = EXCLUDED.sales_points_target_this_week,
        quarterly_sales_points_qtd = EXCLUDED.quarterly_sales_points_qtd,
        won_the_week = EXCLUDED.won_the_week,
        wtw_quotes_restored = EXCLUDED.wtw_quotes_restored,
        updated_at = now()
  RETURNING id INTO v_result_id;

  v_pay_write := public.write_weekly_comp_v2(p_agency_id, v_week_end);

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format(
      'Week %s of 13 (ending %s): carryover=%s, fresh=%s, net=%s, restored=%s, gross_pool=%s, owed_fwd=%s, SP %s/%s, q_pass=%s, sp_pass=%s, won=%s, payroll_rows=%s, mvp=%s',
      v_cycle.week_of_cycle, v_week_end,
      v_team_carryover, v_quotes_fresh_needed, v_team_net_quotes, v_restored_total, v_team_quotes_pool,
      v_quotes_owed_next,
      v_sales_points_qtd, v_sp_target,
      v_quotes_pass, v_sp_pass, v_won,
      v_pay_write->>'rows_updated',
      COALESCE(v_pay_write->'mvp_detection_result'->>'detected', 'false'))
  );
END;
$function$;
