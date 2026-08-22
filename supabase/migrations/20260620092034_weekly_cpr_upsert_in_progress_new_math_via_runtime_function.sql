-- Daily checkin compile path also needs the new math; otherwise every checkin
-- between now and Saturday would re-overwrite quotes_owed_next_week with the
-- stale gross-math 29.
--
-- Behavior change: ignore p_team_quotes_total / p_team_sp_total inputs.
-- Pull team-level outcomes from get_weekly_cpr_requirements (Modified inside
-- Total) so the in-progress snapshot matches the Saturday writer's snapshot
-- and what the page/email render. Win-the-Week still uses gross pool vs total
-- debt (correct), with both sourced from the function for consistency.
CREATE OR REPLACE FUNCTION public.weekly_cpr_upsert_in_progress(p_agency_id uuid, p_today date, p_team_quotes_total numeric, p_team_sp_total numeric)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_wtw record;
  v_week_end date;
  v_team_carryover int := 0;
  v_team_total_debt int := 0;
  v_team_paid int := 0;
  v_team_net_quotes int := 0;
  v_team_quotes_pool int := 0;
  v_quotes_owed_next int := 0;
  v_won boolean;
  v_id uuid;
BEGIN
  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_today);
  v_week_end := v_wtw.week_ending_saturday;

  -- Team-level outcomes from the runtime function (new math).
  SELECT
    COALESCE(SUM(carryover),       0)::int,
    COALESCE(SUM(total),           0)::int,
    COALESCE(SUM(paid),            0)::int,
    COALESCE(SUM(owed),            0)::int,
    COALESCE(SUM(net_quotes),      0)::int,
    COALESCE(SUM(quotes_discussed),0)::int
  INTO
    v_team_carryover, v_team_total_debt, v_team_paid,
    v_quotes_owed_next, v_team_net_quotes, v_team_quotes_pool
  FROM public.get_weekly_cpr_requirements(p_agency_id, v_week_end);

  v_won := (v_team_quotes_pool >= v_team_total_debt)
       AND (p_team_sp_total >= v_wtw.sp_target);

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, quarterly_sales_points_qtd, won_the_week,
    notes, created_at, updated_at
  ) VALUES (
    p_agency_id, v_week_end,
    v_team_carryover, v_wtw.quotes_fresh_needed,
    v_team_net_quotes, v_quotes_owed_next,
    v_wtw.sp_target, p_team_sp_total, v_won,
    'Auto-created by daily checkin pipeline. Updates throughout the week as compiles run. Final state locked by Saturday 23:59 CT writer.',
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
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;
