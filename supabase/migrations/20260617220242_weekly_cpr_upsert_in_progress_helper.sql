-- Helper: UPSERT the in-progress weekly_cpr_reports row for the current week.
-- Called by morning recap + midday compile + EOD compile each daily checkpoint.
-- Saturday 23:59 backstop still runs separately.
--
-- Notes field is set on INSERT but NOT touched on UPDATE, so manual annotations
-- on prior-week rows are preserved.

CREATE OR REPLACE FUNCTION public.weekly_cpr_upsert_in_progress(
  p_agency_id uuid,
  p_today date,
  p_team_quotes_total numeric,
  p_team_sp_total numeric
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $func$
DECLARE
  v_wtw record;
  v_quotes_owed_next int;
  v_won boolean;
  v_id uuid;
BEGIN
  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_today);

  v_quotes_owed_next := GREATEST(0, v_wtw.quotes_target_total - p_team_quotes_total::int);
  v_won := (p_team_quotes_total >= v_wtw.quotes_target_total)
       AND (p_team_sp_total >= v_wtw.sp_target);

  INSERT INTO public.weekly_cpr_reports (
    agency_id, week_ending_date,
    quotes_owed_carryover, quotes_fresh_needed, quotes_total_net, quotes_owed_next_week,
    quarterly_sales_points_target, quarterly_sales_points_qtd, won_the_week,
    notes, created_at, updated_at
  ) VALUES (
    p_agency_id, v_wtw.week_ending_saturday,
    v_wtw.quotes_carryover, v_wtw.quotes_fresh_needed,
    p_team_quotes_total::int, v_quotes_owed_next,
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
$func$;
