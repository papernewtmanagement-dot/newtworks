-- current_cycle_info is the single source for Sales Points quarter boundaries:
-- 13-week (91-day) cycles anchored at settings.cycle_anchor_date (2026-04-05),
-- Sunday start, Saturday end. Q2 2026 = Apr 5 -> Jul 4; Q3 2026 = Jul 5 -> Oct 3.
-- Peter ruling 2026-08-25: the week ending Jul 4 is the CLOSING week of that quarter.
--
-- FIX: integer division truncates toward zero, so any date before the anchor
-- returned the Apr 5 cycle with week 0 or a negative week (Mar 28 -> week 0,
-- Apr 4 -> week 1 of the Apr 5 cycle). Floor division makes pre-anchor dates
-- resolve to the correct earlier cycle (Apr 4 -> Jan 4 .. Apr 4, week 13).
-- Behaviour for dates on/after the anchor is unchanged.

CREATE OR REPLACE FUNCTION public.current_cycle_info(p_agency_id uuid, p_today date DEFAULT NULL::date)
 RETURNS TABLE(cycle_start date, cycle_end date, week_of_cycle integer, week_ending_saturday date, prior_week_ending_saturday date)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_anchor date;
  v_today date;
  v_days_since_anchor int;
  v_cycles_completed int;
  v_days_into_cycle int;
  v_week int;
  v_cycle_start date;
BEGIN
  v_today := COALESCE(p_today, (now() AT TIME ZONE 'America/Chicago')::date);

  SELECT setting_value::date INTO v_anchor
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'cycle_anchor_date';
  IF v_anchor IS NULL THEN v_anchor := '2026-04-05'::date; END IF;

  v_days_since_anchor := v_today - v_anchor;
  -- floor, not truncate: dates before the anchor must fall into the earlier cycle
  v_cycles_completed := floor(v_days_since_anchor / 91.0)::int;
  v_cycle_start := v_anchor + (v_cycles_completed * 91);
  v_days_into_cycle := v_today - v_cycle_start;   -- always 0..90 after the floor
  v_week := (v_days_into_cycle / 7) + 1;

  cycle_start := v_cycle_start;
  cycle_end := v_cycle_start + 90;
  week_of_cycle := v_week;
  week_ending_saturday := v_cycle_start + (v_week * 7) - 1;
  prior_week_ending_saturday := week_ending_saturday - 7;

  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.current_cycle_info(uuid, date) IS
  'Single source for Sales Points quarter (cycle) boundaries. Pass any date, get its 13-week cycle: cycle_start (Sunday), cycle_end (Saturday), week_of_cycle (1-13), week_ending_saturday, prior_week_ending_saturday. Anchored at settings.cycle_anchor_date (2026-04-05). Q2 2026 = Apr 5..Jul 4, Q3 2026 = Jul 5..Oct 3. The week ending Jul 4 closes Q2 (Peter 2026-08-25). Any quarter-aware function (13-wk avg, QTD deltas, quarter close) must call this instead of date_trunc(quarter).';
