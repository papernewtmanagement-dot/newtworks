-- current_cycle_info: SINGLE SOURCE for Sales Points quarter boundaries (State Farm fiscal quarters).
--
-- RULE (Peter 2026-08-25): the Sun-Sat week that contains the calendar quarter's last day
-- belongs to THAT quarter and closes it on its Saturday. The next quarter starts the next Sunday.
--   Q1 2026 = Jan 4 .. Apr 4   Q2 2026 = Apr 5 .. Jul 4   Q3 2026 = Jul 5 .. Oct 3   Q4 2026 = Oct 4 .. Jan 2 2027
--   Q2 2025 = Apr 6 .. Jul 5 (matches the SF Producer Production Report header 04/06/2025-07/05/2025)
-- Quarters are 13 weeks; roughly every 5-6 years one is 14 weeks (Q4 2023 = Oct 1 2023 .. Jan 6 2024,
-- Q4 2028 = Oct 1 2028 .. Jan 6 2029) - that is how a Saturday-ending calendar stays aligned to the
-- calendar quarter. week_of_cycle can therefore be 14 in those quarters.
--
-- WHY THIS REPLACES THE PRIOR VERSION: the prior version stepped fixed 91-day blocks from
-- settings.cycle_anchor_date (2026-04-05). Identical results for 2024-2027, but it drifts one day
-- per year off the calendar and never re-syncs, so it was already one week off for everything before
-- Oct 2023 and will be one week off again from Q4 2028. The anchor setting is no longer read.
-- Signature and return columns unchanged; p_agency_id retained for compatibility (unused).

CREATE OR REPLACE FUNCTION public.current_cycle_info(p_agency_id uuid, p_today date DEFAULT NULL::date)
 RETURNS TABLE(cycle_start date, cycle_end date, week_of_cycle integer, week_ending_saturday date, prior_week_ending_saturday date)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_today       date;
  v_cq_start    date;
  v_cq_end      date;
  v_close       date;
  v_prev_cq_end date;
  v_prev_close  date;
BEGIN
  v_today := COALESCE(p_today, (now() AT TIME ZONE 'America/Chicago')::date);

  -- calendar quarter containing the date
  v_cq_start := date_trunc('quarter', v_today)::date;
  v_cq_end   := (v_cq_start + INTERVAL '3 months')::date - 1;

  -- close = Saturday of the Sun-Sat week containing the calendar quarter's last day (DOW: Sun=0 .. Sat=6)
  v_close       := v_cq_end + (6 - EXTRACT(DOW FROM v_cq_end)::int);
  v_prev_cq_end := v_cq_start - 1;
  v_prev_close  := v_prev_cq_end + (6 - EXTRACT(DOW FROM v_prev_cq_end)::int);

  -- straddle week: the first days of a calendar quarter can still belong to the previous SF quarter
  IF v_today <= v_prev_close THEN
    v_close       := v_prev_close;
    v_prev_cq_end := date_trunc('quarter', v_prev_cq_end)::date - 1;
    v_prev_close  := v_prev_cq_end + (6 - EXTRACT(DOW FROM v_prev_cq_end)::int);
  END IF;

  cycle_start := v_prev_close + 1;
  cycle_end   := v_close;
  week_of_cycle := ((v_today - cycle_start) / 7) + 1;
  week_ending_saturday := cycle_start + (week_of_cycle * 7) - 1;
  prior_week_ending_saturday := week_ending_saturday - 7;

  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.current_cycle_info(uuid, date) IS
  'Single source for Sales Points quarter (State Farm fiscal quarter) boundaries. Pass any date, get its quarter: cycle_start (Sunday), cycle_end (Saturday), week_of_cycle (1-13, occasionally 14), week_ending_saturday, prior_week_ending_saturday. Rule: the Sun-Sat week containing the calendar quarter''s last day closes that quarter. Q2 2026 = Apr 5..Jul 4, Q3 2026 = Jul 5..Oct 3. Any quarter-aware function (13-wk avg, QTD deltas, quarter close, walks) must call this instead of date_trunc(quarter). p_agency_id unused (kept for compatibility).';
