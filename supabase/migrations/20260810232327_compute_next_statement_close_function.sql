-- Found an orphaned, unreferenced function under this same name from an earlier
-- unfinished attempt (compute_next_statement_close(base_date date, close_day smallint)).
-- It used naive "always +1 month" math with no anchor-in-the-past handling, and
-- nothing in the schema or frontend called it. Dropping it rather than leaving
-- two functions with the same name and different, conflicting logic.
DROP FUNCTION IF EXISTS public.compute_next_statement_close(date, smallint);

-- One shared function: given a card/account's fixed statement-close day and
-- the date its last actual statement closed, project the date the NEXT
-- statement is expected to close. Used by both v_bank_balances and
-- v_card_balances so the logic lives in exactly one place.
--
-- If no statement has ever landed for this account, anchors off (as_of - 1)
-- so it still returns a sensible next-occurrence date.
--
-- Clamps to the last real day of short months (Feb, 30-day months) the same
-- way the old backward-looking logic did, so a close_day of 29/30/31 still
-- resolves correctly.
CREATE FUNCTION public.compute_next_statement_close(
  p_close_day smallint,
  p_last_statement_period_end date,
  p_as_of date DEFAULT CURRENT_DATE
) RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT MIN(mc.close_date)
  FROM (
    SELECT COALESCE(p_last_statement_period_end, p_as_of - 1) AS anchor_date
  ) a
  CROSS JOIN LATERAL generate_series(
    date_trunc('month', a.anchor_date),
    date_trunc('month', a.anchor_date) + interval '3 months',
    interval '1 month'
  ) AS month_start(month_start)
  CROSS JOIN LATERAL (
    SELECT (month_start + (LEAST(p_close_day, EXTRACT(day FROM month_start + interval '1 month -1 days')::int) - 1) * interval '1 day')::date AS close_date
  ) mc
  WHERE p_close_day IS NOT NULL
    AND mc.close_date > a.anchor_date
$$;

COMMENT ON FUNCTION public.compute_next_statement_close(smallint, date, date) IS
  'Projects the next expected statement-close date for an account, given its fixed statement_close_day and the last actual statement it received. Returns a date strictly after the anchor (last actual close, or as_of-1 if none yet). Used by v_bank_balances and v_card_balances.';
