-- Saturday 23:59 CT: compute and write/upsert the just-completed week's
-- weekly_cpr_reports row with Win the Week outcome. Leaves SF performance
-- columns (auto_ratio, fire_ratio, claims, code_reds/yellows) NULL — those
-- are populated by separate processes.

CREATE OR REPLACE FUNCTION public.weekly_cpr_compute_outcome(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $func$
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
  v_carryover int := 0;
  v_quotes_total_net int := 0;
  v_sales_points_qtd numeric := 0;
  v_quotes_target_total int;
  v_sp_target numeric;
  v_quotes_owed_next int;
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
  v_week_start := v_week_end - 6;  -- Sunday of this week

  -- Count AMs by category among teammates expected in work checkins
  SELECT
    count(*) FILTER (WHERE role_level = 'Account Manager' AND role_category = 'Sales'),
    count(*) FILTER (WHERE role_level = 'Account Manager' AND role_category = 'Retention')
  INTO v_count_am_sales, v_count_am_retention
  FROM public.team
  WHERE agency_id = p_agency_id AND archived_at IS NULL AND is_test_user IS NOT TRUE
    AND (include_in_team_checkins = true OR
         (include_in_team_checkins IS NULL AND category = 'agency' AND role != 'Owner'));

  v_quotes_fresh_needed := (15 * v_count_am_sales) + (8 * v_count_am_retention);

  -- Carryover = prior week's quotes_owed_next_week (default 0)
  SELECT COALESCE(quotes_owed_next_week, 0) INTO v_carryover
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
  v_carryover := COALESCE(v_carryover, 0);

  -- Actual quotes this week — latest submission per team member within Sun→Sat
  SELECT COALESCE(SUM(latest_q), 0) INTO v_quotes_total_net
  FROM (
    SELECT DISTINCT ON (tc.team_id)
      tc.team_id, tc.quotes_week AS latest_q
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_week_start AND v_week_end
      AND tc.checkin_type IN ('midday', 'eod')
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ) per_member;

  -- Actual SP this quarter — latest submission per team member within the cycle
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

  v_quotes_target_total := v_quotes_fresh_needed + v_carryover;
  v_sp_target := v_cycle.week_of_cycle * ((1000 * v_count_am_sales) + (500 * v_count_am_retention));

  v_quotes_pass := v_quotes_total_net >= v_quotes_target_total;
  v_sp_pass := v_sales_points_qtd >= v_sp_target;
  v_won := v_quotes_pass AND v_sp_pass;
  v_quotes_owed_next := GREATEST(0, v_quotes_target_total - v_quotes_total_net);

  -- UPSERT (week_ending_date may or may not have a row yet; SF columns left untouched)
  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, quarterly_sales_points_qtd, won_the_week,
    created_at, updated_at
  )
  VALUES (
    p_agency_id, v_week_end,
    v_carryover, v_quotes_fresh_needed, v_quotes_total_net, v_quotes_owed_next,
    v_sp_target, v_sales_points_qtd, v_won,
    now(), now()
  )
  ON CONFLICT (agency_id, week_ending_date) DO UPDATE
    SET quotes_owed_carryover = EXCLUDED.quotes_owed_carryover,
        quotes_fresh_needed = EXCLUDED.quotes_fresh_needed,
        quotes_total_net = EXCLUDED.quotes_total_net,
        quotes_owed_next_week = EXCLUDED.quotes_owed_next_week,
        quarterly_sales_points_target = EXCLUDED.quarterly_sales_points_target,
        quarterly_sales_points_qtd = EXCLUDED.quarterly_sales_points_qtd,
        won_the_week = EXCLUDED.won_the_week,
        updated_at = now()
  RETURNING id INTO v_result_id;

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('Week %s of 13 (ending %s): quotes %s/%s, SP %s/%s, won=%s',
      v_cycle.week_of_cycle, v_week_end,
      v_quotes_total_net, v_quotes_target_total,
      v_sales_points_qtd, v_sp_target,
      v_won)
  );
END;
$func$;
