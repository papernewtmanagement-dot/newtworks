-- Fix: cycle-boundary reset for quotes_carryover in get_win_the_week_state
-- AND for sales_points_target_this_week in weekly_cpr_upsert_in_progress overloads.
-- Sales points and quote requirements do NOT carry over between 13-week cycles.
-- weekly_cpr_compute_outcome (Sat-night writer) already had this; readers/in-progress writer did not.

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

  -- Quotes carryover resets at cycle boundary (mirrors SP reset below and weekly_cpr_compute_outcome).
  IF v_cycle.week_of_cycle <= 1 THEN
    v_carryover := 0;
  ELSE
    SELECT COALESCE(quotes_owed_next_week, 0) INTO v_carryover
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
    v_carryover := COALESCE(v_carryover, 0);
  END IF;

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


-- Fix in-progress upsert (no-arg overload): sales_points_target_this_week must not straddle cycle boundary.
CREATE OR REPLACE FUNCTION public.weekly_cpr_upsert_in_progress(p_agency_id uuid, p_today date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_wtw record;
  v_cycle record;
  v_week_end date;
  v_team_carryover int := 0;
  v_team_total_debt int := 0;
  v_team_paid int := 0;
  v_team_net_quotes int := 0;
  v_team_quotes_pool int := 0;
  v_quotes_owed_next int := 0;
  v_sales_points_qtd numeric := 0;
  v_prior_sp_target numeric := 0;
  v_sp_this_week numeric := 0;
  v_won boolean;
  v_id uuid;
BEGIN
  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_today);
  v_week_end := v_wtw.week_ending_saturday;
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_today);

  SELECT
    COALESCE(SUM(total),           0)::int,
    COALESCE(SUM(paid),            0)::int,
    COALESCE(SUM(net_quotes),      0)::int,
    COALESCE(SUM(quotes_discussed),0)::int
  INTO
    v_team_total_debt, v_team_paid, v_team_net_quotes, v_team_quotes_pool
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);

  v_team_carryover := v_wtw.quotes_carryover;
  v_quotes_owed_next := GREATEST(0, v_wtw.quotes_fresh_needed + v_team_carryover - v_team_net_quotes);

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

  v_won := (v_team_quotes_pool >= v_team_total_debt)
       AND (v_sales_points_qtd >= v_wtw.sp_target);

  -- SP-target-this-week: at cycle boundary, don't subtract prior cycle's cumulative target.
  IF v_cycle.week_of_cycle <= 1 THEN
    v_sp_this_week := v_wtw.sp_target;
  ELSE
    SELECT COALESCE(quarterly_sales_points_target, 0) INTO v_prior_sp_target
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
    v_sp_this_week := v_wtw.sp_target - COALESCE(v_prior_sp_target, 0);
  END IF;

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, sales_points_target_this_week,
    quarterly_sales_points_qtd, won_the_week,
    notes, created_at, updated_at
  ) VALUES (
    p_agency_id, v_week_end,
    v_team_carryover, v_wtw.quotes_fresh_needed,
    v_team_net_quotes, v_quotes_owed_next,
    v_wtw.sp_target,
    v_sp_this_week,
    v_sales_points_qtd, v_won,
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

  INSERT INTO public.agency_snapshot (agency_id, snapshot_date, cadence, source, updated_at)
  VALUES (p_agency_id, v_week_end, 'weekly', 'cpr_weekly_manual', now())
  ON CONFLICT (agency_id, snapshot_date, cadence) DO NOTHING;

  RETURN v_id;
END;
$function$;


-- Same fix for the 4-arg overload.
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
  v_team_carryover int := 0;
  v_team_total_debt int := 0;
  v_team_paid int := 0;
  v_team_net_quotes int := 0;
  v_team_quotes_pool int := 0;
  v_quotes_owed_next int := 0;
  v_sales_points_qtd numeric := 0;
  v_prior_sp_target numeric := 0;
  v_sp_this_week numeric := 0;
  v_won boolean;
  v_id uuid;
BEGIN
  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_today);
  v_week_end := v_wtw.week_ending_saturday;
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_today);

  SELECT
    COALESCE(SUM(total),           0)::int,
    COALESCE(SUM(paid),            0)::int,
    COALESCE(SUM(net_quotes),      0)::int,
    COALESCE(SUM(quotes_discussed),0)::int
  INTO
    v_team_total_debt, v_team_paid, v_team_net_quotes, v_team_quotes_pool
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);

  v_team_carryover := v_wtw.quotes_carryover;
  v_quotes_owed_next := GREATEST(0, v_wtw.quotes_fresh_needed + v_team_carryover - v_team_net_quotes);

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

  v_won := (v_team_quotes_pool >= v_team_total_debt)
       AND (v_sales_points_qtd >= v_wtw.sp_target);

  IF v_cycle.week_of_cycle <= 1 THEN
    v_sp_this_week := v_wtw.sp_target;
  ELSE
    SELECT COALESCE(quarterly_sales_points_target, 0) INTO v_prior_sp_target
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
    v_sp_this_week := v_wtw.sp_target - COALESCE(v_prior_sp_target, 0);
  END IF;

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, sales_points_target_this_week,
    quarterly_sales_points_qtd, won_the_week,
    notes, created_at, updated_at
  ) VALUES (
    p_agency_id, v_week_end,
    v_team_carryover, v_wtw.quotes_fresh_needed,
    v_team_net_quotes, v_quotes_owed_next,
    v_wtw.sp_target,
    v_sp_this_week,
    v_sales_points_qtd, v_won,
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
