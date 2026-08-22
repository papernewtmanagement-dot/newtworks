-- Fix: compute_next_statement_close was returning the SAME month's close_day
-- as "next" when actual close date fell shortly before nominal close_day
-- (e.g. close 7/21 with close_day=22 returned 7/22, but that IS the cycle
-- boundary we just closed). Correct semantic: given base_date = last actual
-- statement close, next expected close is close_day of the FOLLOWING month
-- (clamped to that month's length for Feb / 30-day months).
--
-- Consumers: v_bank_balances, v_card_balances (both reference this in the
-- next_statement_expected_date + statement_overdue projections).

CREATE OR REPLACE FUNCTION public.compute_next_statement_close(base_date date, close_day smallint)
RETURNS date
LANGUAGE sql
IMMUTABLE
AS $function$
  WITH next_month AS (
    SELECT date_trunc('month', base_date + interval '1 month')::date AS month_start
  ),
  clamped AS (
    SELECT month_start,
           LEAST(close_day, extract(day from (month_start + interval '1 month - 1 day'))::int) AS day
    FROM next_month
  )
  SELECT (month_start + ((day - 1) * interval '1 day'))::date
  FROM clamped;
$function$;
