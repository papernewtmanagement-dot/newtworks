-- The numbers the day-done panel shows. One person, the CPR week so far.
-- Every figure comes from the function that already owns it, so this adds
-- no second definition of anything: rp_sales_week_growth for the week's
-- sales points, compute_weekly_retention_points for retention, and
-- rp_week_rollup for the conversation and service counts.
CREATE OR REPLACE FUNCTION public.my_week_stats(p_week_ending date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_me       uuid := public.current_team_member_id();
  v_agency   uuid;
  v_today    date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_end date;
  v_sales    numeric;
  v_ret      numeric;
  v_quotes   int;
  v_sold     int;
  v_conv     int;
  v_avg      numeric;
  v_reviews  int;
  v_pivots   int;
BEGIN
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_team_member');
  END IF;

  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;
  v_week_end := COALESCE(p_week_ending, v_today + (6 - EXTRACT(DOW FROM v_today)::int));

  SELECT g.growth INTO v_sales
  FROM public.rp_sales_week_growth(v_agency, v_week_end) g
  WHERE g.team_member_id = v_me;

  SELECT r.net_points INTO v_ret
  FROM public.compute_weekly_retention_points(v_agency, v_week_end) r
  WHERE r.team_member_id = v_me;

  SELECT count(DISTINCT q.customer_label || COALESCE(q.phone_last4, ''))::int INTO v_quotes
  FROM public.quote_log q
  WHERE q.agency_id = v_agency AND q.status = 'active'
    AND q.team_member_id = v_me AND q.week_end_date = v_week_end;

  SELECT count(DISTINCT s.customer_label || COALESCE(s.phone_last4, ''))::int INTO v_sold
  FROM public.sales_log s
  WHERE s.agency_id = v_agency AND s.status = 'active'
    AND s.team_member_id = v_me AND s.week_end_date = v_week_end;

  SELECT c.scorecards, c.scorecard_avg, c.policy_reviews, c.pivots
    INTO v_conv, v_avg, v_reviews, v_pivots
  FROM public.rp_week_rollup(v_week_end, v_me) c;

  RETURN jsonb_build_object(
    'ok', true,
    'week_ending', v_week_end,
    'sales_points', ROUND(COALESCE(v_sales, 0), 2),
    'retention_points', ROUND(COALESCE(v_ret, 0), 2),
    'quotes', COALESCE(v_quotes, 0),
    'sales', COALESCE(v_sold, 0),
    'conversations', COALESCE(v_conv, 0),
    'conversation_avg', v_avg,
    'policy_reviews', COALESCE(v_reviews, 0),
    'pivots', COALESCE(v_pivots, 0)
  );
END $$;

GRANT EXECUTE ON FUNCTION public.my_week_stats(date) TO authenticated;
