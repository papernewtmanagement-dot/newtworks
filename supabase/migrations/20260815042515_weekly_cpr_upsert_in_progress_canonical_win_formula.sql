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
  v_team_net_quotes numeric := 0;
  v_team_quotes_pool int := 0;
  v_step1_total int := 0;
  v_quotes_owed_next int := 0;
  v_sales_points_qtd numeric := 0;
  v_prior_sp_target numeric := 0;
  v_sp_this_week numeric := 0;
  v_raw_pass boolean;
  v_sp_pass boolean;
  v_eligible boolean;
  v_step2_total int;
  v_effective_net numeric;
  v_won boolean;
  v_restored_total int;
  v_id uuid;
  v_totals record;
BEGIN
  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_today);
  v_week_end := v_wtw.week_ending_saturday;
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_today);

  -- get_weekly_cpr_requirements' net_quotes already includes the individual WtW requirements
  -- buy-back (locked 2026-08-15) — canonical formula matches recompute_cpr_outcome /
  -- weekly_cpr_compute_outcome now (this function previously used a different, non-canonical
  -- raw-pool-vs-total-debt comparison that didn't know about the buy-back at all).
  SELECT
    COALESCE(SUM(total),            0)::int,
    COALESCE(SUM(net_quotes),       0),
    COALESCE(SUM(quotes_discussed), 0)::int,
    COALESCE(SUM(buyback),          0)::int
  INTO
    v_quotes_owed_next, v_team_net_quotes, v_team_quotes_pool, v_step1_total
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);
  -- (v_quotes_owed_next reused below as scratch for team_total_debt; overwritten with the
  -- real owed-next-week figure further down once the canonical formula has run.)

  v_team_carryover := v_wtw.quotes_carryover;

  -- Single shared calculation (get_team_checkin_totals) — fixed 2026-08-12, see function comment.
  SELECT * INTO v_totals FROM public.get_team_checkin_totals(p_agency_id, v_cycle.cycle_start, v_week_end);
  v_sales_points_qtd := v_totals.total_sales_points;

  v_sp_pass  := v_sales_points_qtd >= v_wtw.sp_target;
  v_raw_pass := v_team_quotes_pool >= (v_wtw.quotes_fresh_needed + v_team_carryover);
  v_eligible := v_raw_pass AND v_sp_pass;

  v_step2_total := CASE WHEN v_eligible THEN GREATEST(0, v_wtw.quotes_fresh_needed + v_team_carryover - v_team_net_quotes) ELSE 0 END;
  v_effective_net := v_team_net_quotes + v_step2_total;
  v_restored_total := v_step1_total + v_step2_total;

  v_won := (v_effective_net >= (v_wtw.quotes_fresh_needed + v_team_carryover)) AND v_sp_pass;
  v_quotes_owed_next := GREATEST(0, v_wtw.quotes_fresh_needed + v_team_carryover - v_effective_net);

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
    quarterly_sales_points_qtd, won_the_week, wtw_quotes_restored,
    notes, created_at, updated_at
  ) VALUES (
    p_agency_id, v_week_end,
    v_team_carryover, v_wtw.quotes_fresh_needed,
    v_team_net_quotes, v_quotes_owed_next,
    v_wtw.sp_target,
    v_sp_this_week,
    v_sales_points_qtd, v_won, v_restored_total,
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
        wtw_quotes_restored = EXCLUDED.wtw_quotes_restored,
        updated_at = now()
  RETURNING id INTO v_id;

  INSERT INTO public.agency_snapshot (agency_id, snapshot_date, cadence, source, updated_at)
  VALUES (p_agency_id, v_week_end, 'weekly', 'cpr_weekly_manual', now())
  ON CONFLICT (agency_id, snapshot_date, cadence) DO NOTHING;

  RETURN v_id;
END;
$function$;
