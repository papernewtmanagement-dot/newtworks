-- Peter 2026-10-08: carried-over prizes are never subtracted from the prize cart budget.
-- The whole quarterly budget is for new prizes. Totals count only prizes new this quarter.
DO $$
DECLARE v_def text; v_old text;
BEGIN
  -- Review: totals and the no-price count are for new prizes only.
  v_def := pg_get_functiondef('public.prize_cart_review()'::regprocedure);
  v_old := $o$         COALESCE(sum(p.prize_value), 0),
         count(*) FILTER (WHERE p.prize_value IS NULL),$o$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'review totals not found'; END IF;
  v_def := replace(v_def, v_old, $n$         COALESCE(sum(p.prize_value) FILTER (WHERE p.is_new_this_quarter), 0),  -- carryovers never count against the budget (Peter 2026-10-08)
         count(*) FILTER (WHERE p.prize_value IS NULL AND p.is_new_this_quarter),$n$);
  EXECUTE v_def;

  -- Alvi's message: same total, carryovers marked as not counted.
  v_def := pg_get_functiondef('public.prize_cart_send_for_approval()'::regprocedure);
  v_old := $o$           || CASE WHEN p.proposed THEN '' ELSE ' (carried over)' END,
           chr(10) ORDER BY p.display_order),
         COALESCE(sum(p.prize_value), 0)$o$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'send totals not found'; END IF;
  v_def := replace(v_def, v_old, $n$           || CASE WHEN p.is_new_this_quarter THEN '' ELSE ' (carried over, not counted)' END,
           chr(10) ORDER BY p.display_order),
         COALESCE(sum(p.prize_value) FILTER (WHERE p.is_new_this_quarter), 0)$n$);
  EXECUTE v_def;

  -- Quarter close: the full budget is available for new prizes.
  v_def := pg_get_functiondef('public.quarter_close_prize_cart_and_leaderboards(uuid,date)'::regprocedure);
  v_old := 'v_available_budget := ROUND(v_next_budget - v_carried_value_total, 2);';
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'close available line not found'; END IF;
  v_def := replace(v_def, v_old, 'v_available_budget := v_next_budget;  -- carryovers are never subtracted from the budget (Peter 2026-10-08)');
  EXECUTE v_def;
END $$;
