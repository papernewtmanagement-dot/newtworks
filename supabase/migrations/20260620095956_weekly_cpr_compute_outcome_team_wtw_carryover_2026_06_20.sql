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
  v_prior_sp_cumulative numeric;
  v_sp_target numeric;
  v_won boolean;
  v_quotes_pass boolean;
  v_sp_pass boolean;
  v_result_id uuid;
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

  -- Team composition snapshot at week start (for fresh_needed + SP increment).
  SELECT
    count(*) FILTER (WHERE role_level IN ('Account Manager', 'Unit Manager') AND role_category = 'Sales'),
    count(*) FILTER (WHERE role_level IN ('Account Manager', 'Unit Manager') AND role_category = 'Retention')
  INTO v_count_am_sales, v_count_am_retention
  FROM public.team
  WHERE agency_id = p_agency_id
    AND (archived_at IS NULL OR archived_at > v_week_start::timestamptz)
    AND is_test_user IS NOT TRUE
    AND (include_in_team_checkins = true OR
         (include_in_team_checkins IS NULL AND category = 'agency' AND role != 'Owner'));

  v_quotes_fresh_needed := (15 * v_count_am_sales) + (8 * v_count_am_retention);
  v_this_week_sp_increment := (1000 * v_count_am_sales) + (500 * v_count_am_retention);

  -- Per-person checklist chain — used for team_net_quotes (sum of per-person
  -- quotes_discussed − paid) and the gross quotes pool (informational). The
  -- per-person chain's notion of "carryover" is a SEPARATE concept from the
  -- team-level Win-the-Week deficit and is no longer used here.
  SELECT
    COALESCE(SUM(net_quotes),       0)::int,
    COALESCE(SUM(quotes_discussed), 0)::int
  INTO
    v_team_net_quotes, v_team_quotes_pool
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);

  -- Team-level Win-the-Week carryover comes from the prior week's stored
  -- quotes_owed_next_week. This is the authoritative team-level deficit seed.
  -- Carryover resets to 0 at cycle start (week 1).
  IF v_cycle.week_of_cycle <= 1 THEN
    v_team_carryover := 0;
  ELSE
    SELECT COALESCE(quotes_owed_next_week, 0) INTO v_team_carryover
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id
      AND week_ending_date = v_cycle.prior_week_ending_saturday;
    v_team_carryover := COALESCE(v_team_carryover, 0);
  END IF;

  -- Sales points QTD: latest per member from Telegram checkins, cycle-to-date.
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

  v_sp_target := v_prior_sp_cumulative + v_this_week_sp_increment;

  -- Team-level Win-the-Week: NET quotes against (carryover + fresh_needed).
  -- Per-person chain math (which uses missed × cost) handles per-person
  -- checklist debt and Payroll allocation separately and is NOT used here.
  v_quotes_pass := v_team_net_quotes >= (v_quotes_fresh_needed + v_team_carryover);
  v_sp_pass := v_sales_points_qtd >= v_sp_target;
  v_won := v_quotes_pass AND v_sp_pass;

  -- Team-level owed forward = max(0, fresh + carryover − team net quotes).
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

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format(
      'Week %s of 13 (ending %s): carryover=%s, fresh=%s, net=%s, gross_pool=%s, owed_fwd=%s, SP %s/%s, q_pass=%s, sp_pass=%s, won=%s',
      v_cycle.week_of_cycle, v_week_end,
      v_team_carryover, v_quotes_fresh_needed, v_team_net_quotes, v_team_quotes_pool,
      v_quotes_owed_next,
      v_sales_points_qtd, v_sp_target,
      v_quotes_pass, v_sp_pass, v_won)
  );
END;
$function$;
