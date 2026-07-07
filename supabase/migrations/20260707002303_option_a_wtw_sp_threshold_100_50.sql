-- Option A: WtW Condition 2 SP threshold rebased to 100 (AM-Sales) / 50 (AM-Retention).
-- Prior code carried stale 1000/500 (never updated through 300/150 memory era).
-- Under new residual-pool comp: 1 SP = $1 direct commission (locked 2026-07-06).
-- Threshold 100 lands first cumulative win at Week 3 under linear Q1 pace with no push.
-- Ratio 2:1 sales:retention preserved (50% AM-Retention weight per calibration op-rule).

CREATE OR REPLACE FUNCTION public.get_win_the_week_state(p_agency_id uuid, p_today date DEFAULT NULL::date)
 RETURNS TABLE(week_of_cycle integer, week_ending_saturday date, count_am_sales integer, count_am_retention integer, quotes_fresh_needed integer, quotes_carryover integer, quotes_target_total integer, sp_target numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_today date;
  v_cycle record;
  v_week_start date;
  v_am_sales int := 0;
  v_am_retention int := 0;
  v_carryover int := 0;
  v_this_week_sp_increment numeric;
  v_prior_sp_cumulative numeric;
BEGIN
  v_today := COALESCE(p_today, (now() AT TIME ZONE 'America/Chicago')::date);
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, v_today);
  v_week_start := v_cycle.week_ending_saturday - 6;

  SELECT count(*)::int INTO v_am_sales
  FROM public.get_expected_teammates(p_agency_id, 'wtw_am_sales', v_week_start);

  SELECT count(*)::int INTO v_am_retention
  FROM public.get_expected_teammates(p_agency_id, 'wtw_am_retention', v_week_start);

  SELECT COALESCE(quotes_owed_next_week, 0) INTO v_carryover
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
  v_carryover := COALESCE(v_carryover, 0);

  -- Option A (2026-07-06): 100 per AM-Sales + 50 per AM-Retention.
  v_this_week_sp_increment := (100 * v_am_sales) + (50 * v_am_retention);

  IF v_cycle.week_of_cycle <= 1 THEN
    v_prior_sp_cumulative := 0;
  ELSE
    SELECT quarterly_sales_points_target INTO v_prior_sp_cumulative
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
    IF v_prior_sp_cumulative IS NULL THEN
      v_prior_sp_cumulative := (v_cycle.week_of_cycle - 1) * v_this_week_sp_increment;
    END IF;
  END IF;

  week_of_cycle := v_cycle.week_of_cycle;
  week_ending_saturday := v_cycle.week_ending_saturday;
  count_am_sales := v_am_sales;
  count_am_retention := v_am_retention;
  quotes_fresh_needed := (15 * v_am_sales) + (8 * v_am_retention);
  quotes_carryover := v_carryover;
  quotes_target_total := quotes_fresh_needed + v_carryover;
  sp_target := v_prior_sp_cumulative + v_this_week_sp_increment;

  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.compute_cumulative_sp_target(p_agency_id uuid, p_through_week integer, p_cycle_start date)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_total numeric := 0;
  v_week_start date;
  v_am_sales int;
  v_am_retention int;
  w int;
BEGIN
  IF p_through_week < 1 THEN RETURN 0; END IF;

  FOR w IN 1..p_through_week LOOP
    v_week_start := p_cycle_start + ((w - 1) * 7);
    SELECT c.am_sales, c.am_retention
      INTO v_am_sales, v_am_retention
      FROM public.get_wtw_am_counts(p_agency_id, v_week_start) c;
    v_total := v_total + (100 * v_am_sales) + (50 * v_am_retention);
  END LOOP;

  RETURN v_total;
END;
$function$;

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
  v_count_am_sales int := 0;
  v_count_am_retention int := 0;
  v_quotes_fresh_needed int;
  v_team_carryover int := 0;
  v_team_net_quotes int := 0;
  v_team_quotes_pool int := 0;
  v_quotes_owed_next int := 0;
  v_sales_points_qtd numeric := 0;
  v_this_week_sp_increment numeric;
  v_sp_target numeric;
  v_won boolean;
  v_quotes_pass boolean;
  v_sp_pass boolean;
  v_result_id uuid;
  v_pay_write jsonb;
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

  SELECT c.am_sales, c.am_retention
    INTO v_count_am_sales, v_count_am_retention
    FROM public.get_wtw_am_counts(p_agency_id, v_week_start) c;

  v_quotes_fresh_needed := (15 * v_count_am_sales) + (8 * v_count_am_retention);
  -- Option A (2026-07-06): 100/50 per AM-Sales/AM-Retention.
  v_this_week_sp_increment := (100 * v_count_am_sales) + (50 * v_count_am_retention);

  SELECT
    COALESCE(SUM(net_quotes),       0)::int,
    COALESCE(SUM(quotes_discussed), 0)::int
  INTO
    v_team_net_quotes, v_team_quotes_pool
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

  SELECT COALESCE(SUM(latest_sp), 0) INTO v_sales_points_qtd
  FROM (
    SELECT DISTINCT ON (tc.team_id)
      tc.team_id, tc.sales_points_quarter AS latest_sp
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_cycle.cycle_start AND v_week_end
      AND tc.checkin_type IN ('midday', 'eod')
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ) per_member;

  v_quotes_pass := v_team_net_quotes >= (v_quotes_fresh_needed + v_team_carryover);
  v_sp_pass := v_sales_points_qtd >= v_sp_target;
  v_won := v_quotes_pass AND v_sp_pass;

  v_quotes_owed_next := GREATEST(0, v_quotes_fresh_needed + v_team_carryover - v_team_net_quotes);

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, sales_points_target_this_week,
    quarterly_sales_points_qtd, won_the_week,
    created_at, updated_at
  )
  VALUES (
    p_agency_id, v_week_end,
    v_team_carryover, v_quotes_fresh_needed, v_team_net_quotes, v_quotes_owed_next,
    v_sp_target, v_this_week_sp_increment,
    v_sales_points_qtd, v_won,
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
        updated_at = now()
  RETURNING id INTO v_result_id;

  v_pay_write := public.write_weekly_pay(p_agency_id, v_week_end);

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format(
      'Week %s of 13 (ending %s): carryover=%s, fresh=%s, net=%s, gross_pool=%s, owed_fwd=%s, SP %s/%s, q_pass=%s, sp_pass=%s, won=%s, payroll_rows=%s',
      v_cycle.week_of_cycle, v_week_end,
      v_team_carryover, v_quotes_fresh_needed, v_team_net_quotes, v_team_quotes_pool,
      v_quotes_owed_next,
      v_sales_points_qtd, v_sp_target,
      v_quotes_pass, v_sp_pass, v_won,
      v_pay_write->>'rows_updated')
  );
END;
$function$;
