-- Win-the-Week cumulative SP target fix.
-- Bug: get_win_the_week_state computed sp_target = week_of_cycle × current_AM_count × 1000,
-- silently rewriting prior weeks' required points when someone was archived mid-cycle.
-- Fix: cumulative sum of per-week increments, each snapshotted to that week's Monday morning.
-- Also fixes weekly_cpr_upsert_in_progress to use concept B (prior-week stored owed_next_week)
-- for quotes_owed_carryover instead of summing per-person concept A chain-debt.

-- Helper 1: AM-equivalent counts at a given week start (Sunday of that week).
-- Same filter shape as weekly_cpr_compute_outcome snapshot — matches snapshot policy.
CREATE OR REPLACE FUNCTION public.get_wtw_am_counts(
  p_agency_id uuid,
  p_week_start date
)
RETURNS TABLE(am_sales int, am_retention int)
LANGUAGE plpgsql STABLE
SET search_path TO 'public', 'extensions'
AS $$
BEGIN
  RETURN QUERY
  SELECT
    count(*) FILTER (WHERE t.role_level IN ('Account Manager','Unit Manager') AND t.role_category = 'Sales')::int,
    count(*) FILTER (WHERE t.role_level IN ('Account Manager','Unit Manager') AND t.role_category = 'Retention')::int
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND t.is_test_user IS NOT TRUE
    AND (t.include_in_team_checkins = true OR
         (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner'))
    AND (t.archived_at IS NULL OR t.archived_at > p_week_start::timestamptz);
END;
$$;

-- Helper 2: cumulative SP target from cycle_start through given week.
-- Each week contributes (1000 × AM-Sales-then) + (500 × AM-Retention-then).
-- Past weeks stay locked at their roster; current week reflects current roster.
CREATE OR REPLACE FUNCTION public.compute_cumulative_sp_target(
  p_agency_id uuid,
  p_through_week int,
  p_cycle_start date
)
RETURNS numeric
LANGUAGE plpgsql STABLE
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_total numeric := 0;
  v_week_start date;
  v_am_sales int;
  v_am_retention int;
  w int;
BEGIN
  IF p_through_week < 1 THEN RETURN 0; END IF;

  FOR w IN 1..p_through_week LOOP
    v_week_start := p_cycle_start + ((w - 1) * 7);  -- Sunday of week w
    SELECT c.am_sales, c.am_retention
      INTO v_am_sales, v_am_retention
      FROM public.get_wtw_am_counts(p_agency_id, v_week_start) c;
    v_total := v_total + (1000 * v_am_sales) + (500 * v_am_retention);
  END LOOP;

  RETURN v_total;
END;
$$;

-- Updated get_win_the_week_state: cumulative sp_target, snapshot for current week's fresh need.
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
BEGIN
  v_today := COALESCE(p_today, (now() AT TIME ZONE 'America/Chicago')::date);
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, v_today);
  v_week_start := v_cycle.week_ending_saturday - 6;  -- Sunday of current week

  -- Current week roster snapshot (Monday-morning principle).
  SELECT c.am_sales, c.am_retention
    INTO v_am_sales, v_am_retention
    FROM public.get_wtw_am_counts(p_agency_id, v_week_start) c;

  -- Team-level quote deficit from prior week (concept B, per WtW canon).
  SELECT COALESCE(quotes_owed_next_week, 0) INTO v_carryover
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
  v_carryover := COALESCE(v_carryover, 0);

  week_of_cycle := v_cycle.week_of_cycle;
  week_ending_saturday := v_cycle.week_ending_saturday;
  count_am_sales := v_am_sales;
  count_am_retention := v_am_retention;
  quotes_fresh_needed := (15 * v_am_sales) + (8 * v_am_retention);
  quotes_carryover := v_carryover;
  quotes_target_total := quotes_fresh_needed + v_carryover;

  -- Cumulative SP target: prior weeks locked at their roster + this week at current roster.
  sp_target := public.compute_cumulative_sp_target(p_agency_id, v_cycle.week_of_cycle, v_cycle.cycle_start);

  RETURN NEXT;
END;
$function$;

-- Updated weekly_cpr_compute_outcome: cumulative SP target via helper (no fragile prior-row chain).
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

  -- This-week roster snapshot.
  SELECT c.am_sales, c.am_retention
    INTO v_count_am_sales, v_count_am_retention
    FROM public.get_wtw_am_counts(p_agency_id, v_week_start) c;

  v_quotes_fresh_needed := (15 * v_count_am_sales) + (8 * v_count_am_retention);
  v_this_week_sp_increment := (1000 * v_count_am_sales) + (500 * v_count_am_retention);

  SELECT
    COALESCE(SUM(net_quotes),       0)::int,
    COALESCE(SUM(quotes_discussed), 0)::int
  INTO
    v_team_net_quotes, v_team_quotes_pool
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);

  -- Concept B carryover: prior week's team-level owed_next_week (NOT sum of per-person chain).
  IF v_cycle.week_of_cycle <= 1 THEN
    v_team_carryover := 0;
  ELSE
    SELECT COALESCE(quotes_owed_next_week, 0) INTO v_team_carryover
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id
      AND week_ending_date = v_cycle.prior_week_ending_saturday;
    v_team_carryover := COALESCE(v_team_carryover, 0);
  END IF;

  -- Cumulative SP target via helper. Past weeks stay locked at their then-roster.
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

-- Updated weekly_cpr_upsert_in_progress: concept B carryover + write sp_target_this_week.
CREATE OR REPLACE FUNCTION public.weekly_cpr_upsert_in_progress(p_agency_id uuid, p_today date, p_team_quotes_total numeric, p_team_sp_total numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_wtw record;
  v_cycle record;
  v_week_end date;
  v_week_start date;
  v_team_carryover int := 0;
  v_team_net_quotes int := 0;
  v_team_quotes_pool int := 0;
  v_quotes_owed_next int := 0;
  v_this_week_sp_increment numeric;
  v_won boolean;
  v_id uuid;
BEGIN
  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_today);
  v_week_end := v_wtw.week_ending_saturday;
  v_week_start := v_week_end - 6;

  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_today);

  -- Net quotes + gross pool from per-person runtime.
  SELECT
    COALESCE(SUM(net_quotes),      0)::int,
    COALESCE(SUM(quotes_discussed),0)::int
  INTO
    v_team_net_quotes, v_team_quotes_pool
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);

  -- Concept B carryover: prior week's stored team-level owed_next_week.
  IF v_cycle.week_of_cycle <= 1 THEN
    v_team_carryover := 0;
  ELSE
    SELECT COALESCE(quotes_owed_next_week, 0) INTO v_team_carryover
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id
      AND week_ending_date = v_cycle.prior_week_ending_saturday;
    v_team_carryover := COALESCE(v_team_carryover, 0);
  END IF;

  v_quotes_owed_next := GREATEST(0, v_wtw.quotes_fresh_needed + v_team_carryover - v_team_net_quotes);

  v_this_week_sp_increment := (1000 * v_wtw.count_am_sales) + (500 * v_wtw.count_am_retention);

  v_won := (v_team_net_quotes >= (v_wtw.quotes_fresh_needed + v_team_carryover))
       AND (p_team_sp_total >= v_wtw.sp_target);

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, sales_points_target_this_week,
    quarterly_sales_points_qtd, won_the_week,
    notes, created_at, updated_at
  ) VALUES (
    p_agency_id, v_week_end,
    v_team_carryover, v_wtw.quotes_fresh_needed, v_team_net_quotes, v_quotes_owed_next,
    v_wtw.sp_target, v_this_week_sp_increment,
    p_team_sp_total, v_won,
    'Auto-created by daily checkin pipeline. Updates throughout the week as compiles run. Final state locked by Saturday 23:59 CT writer.',
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
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;
