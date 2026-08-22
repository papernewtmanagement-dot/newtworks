-- ============================================================================
-- Win the Week — fix 3 related bugs surfaced when Jason was archived 6/20:
--   (1) get_win_the_week_state retroactively shrinks sp_target on archive
--   (2) weekly_cpr_upsert_in_progress writes wrong carryover + QTD (and hence
--       overwrites a correct Saturday-writer row with bad numbers during week)
--   (3) team_checkin_compile_results drops archived members' QTD from "Team:"
-- All three now mirror weekly_cpr_compute_outcome (Saturday writer) which has
-- always been correct.
-- ============================================================================

-- (1) get_win_the_week_state ----------------------------------------------------
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

  -- AM count uses Monday-morning snapshot (matches weekly_cpr_compute_outcome).
  -- Anyone archived BEFORE the week started is excluded; anyone archived
  -- during/after the week still counts toward THIS week's increment.
  SELECT
    count(*) FILTER (WHERE role_level IN ('Account Manager', 'Unit Manager') AND role_category = 'Sales'),
    count(*) FILTER (WHERE role_level IN ('Account Manager', 'Unit Manager') AND role_category = 'Retention')
  INTO v_am_sales, v_am_retention
  FROM public.team
  WHERE agency_id = p_agency_id
    AND is_test_user IS NOT TRUE
    AND (archived_at IS NULL OR archived_at > v_week_start::timestamptz)
    AND (include_in_team_checkins = true OR
         (include_in_team_checkins IS NULL AND category = 'agency' AND role != 'Owner'));

  -- Quote carryover from prior week's stored Concept-B value
  SELECT COALESCE(quotes_owed_next_week, 0) INTO v_carryover
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
  v_carryover := COALESCE(v_carryover, 0);

  v_this_week_sp_increment := (1000 * v_am_sales) + (500 * v_am_retention);

  -- Stack: prior cumulative target + this week's increment using current snapshot
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

-- (2) weekly_cpr_upsert_in_progress --------------------------------------------
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
  v_team_carryover int := 0;          -- Concept B (canon: prior week's quotes_owed_next_week)
  v_team_total_debt int := 0;         -- Concept A (per-person chain) — used for v_won quotes check
  v_team_paid int := 0;
  v_team_net_quotes int := 0;
  v_team_quotes_pool int := 0;
  v_quotes_owed_next int := 0;
  v_sales_points_qtd numeric := 0;
  v_won boolean;
  v_id uuid;
BEGIN
  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_today);
  v_week_end := v_wtw.week_ending_saturday;
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_today);

  -- Per-person chain totals (used for total-debt check that drives v_won quotes leg)
  SELECT
    COALESCE(SUM(total),           0)::int,
    COALESCE(SUM(paid),            0)::int,
    COALESCE(SUM(net_quotes),      0)::int,
    COALESCE(SUM(quotes_discussed),0)::int
  INTO
    v_team_total_debt, v_team_paid, v_team_net_quotes, v_team_quotes_pool
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);

  -- Canon: carryover stored = Concept B (prior week's quotes_owed_next_week), not chain sum
  v_team_carryover := v_wtw.quotes_carryover;

  v_quotes_owed_next := GREATEST(0, v_wtw.quotes_fresh_needed + v_team_carryover - v_team_net_quotes);

  -- QTD sales points across ALL members who reported during the quarter
  -- (DISTINCT ON team_id, no archived filter — mirrors weekly_cpr_compute_outcome).
  -- Preserves prior-week contributions from members who have since been archived.
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
    (v_wtw.sp_target - COALESCE((SELECT quarterly_sales_points_target FROM public.weekly_cpr_reports WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday), 0)),
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
