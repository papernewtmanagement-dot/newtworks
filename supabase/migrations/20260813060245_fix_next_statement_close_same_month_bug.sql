CREATE OR REPLACE FUNCTION public.compute_next_statement_close(p_close_day smallint, p_last_statement_period_end date, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
  -- Always project into the month AFTER the anchor's month, never the same month.
  -- Anchor = the last actual statement close (or as_of-1 if none exist yet).
  -- A real statement often closes 1-2 days off its nominal close_day (weekends/
  -- holidays), so "close_date > anchor_date" alone is not a safe filter: when
  -- close_day is a couple days later in the calendar than the anchor's actual
  -- close day, a same-month candidate can slip through and get returned as
  -- "next," even though that month's statement already closed. Starting the
  -- candidate range at anchor_month + 1 guarantees a genuine next cycle.
  SELECT MIN(mc.close_date)
  FROM (
    SELECT COALESCE(p_last_statement_period_end, p_as_of - 1) AS anchor_date
  ) a
  CROSS JOIN LATERAL generate_series(
    date_trunc('month', a.anchor_date) + interval '1 month',
    date_trunc('month', a.anchor_date) + interval '4 months',
    interval '1 month'
  ) AS month_start(month_start)
  CROSS JOIN LATERAL (
    SELECT (month_start + (LEAST(p_close_day, EXTRACT(day FROM month_start + interval '1 month -1 days')::int) - 1) * interval '1 day')::date AS close_date
  ) mc
  WHERE p_close_day IS NOT NULL
$function$;
