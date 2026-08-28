-- current_cycle_info — THE single source of quarter boundaries. Nothing else computes them.
--
-- PETER DIRECTIVE 2026-08-28, verbatim: "Our quarters are 13 weeks. They close on the last
-- Saturday of the 13 weeks. That's it. There should only be one function that calculates that."
--
-- WHAT THIS RESTORES AND WHY. The original design (migration 20260617213312) was exactly that:
-- 91-day cycles from settings.cycle_anchor_date, Sunday start, Saturday close. On 2026-08-25
-- migration 20260825182251 replaced it with CALENDAR anchoring — re-deriving each close from
-- date_trunc('quarter'). Peter's ruling that day was about the BOUNDARY DATES (Q3 2026 = Jul 5
-- to Oct 3); the calendar mechanism, and the 14-week quarters it produces to stay glued to the
-- calendar, were not his call. They are the reason Q4 2023 read 14 weeks and Q1 2029 read 12.
-- Under a strict 13-week rule no such quarter exists. Reverting to it.
--
-- ZERO IMPACT ON LIVE DATA, verified before applying: strict-91-day and calendar-anchored return
-- byte-identical cycle_start/cycle_end for every cycle from 2024-01-07 through 2028-09-30. Every
-- weekly_cpr_reports row, every comp run and every sales_points close sits inside that window,
-- so no pay, no bonus pool and no leaderboard figure moves. They diverge only before 2024 and
-- from Q4 2028 on.
--
-- THE LABEL LIVES HERE TOO. Callers must never derive a quarter name themselves — that was the
-- 2026-08-28 CPR bug, where the page read the label off the close Saturday's calendar month and
-- every column sat one quarter too high. Label is taken from the cycle MIDPOINT (cycle_start+45),
-- not from cycle_start: under strict 13-week stepping the start drifts earlier each year and by
-- 2028-12-31 a cycle starts in the previous calendar quarter, which would emit "Q4 2028" twice.
-- Midpoint is correct across 2022-2030 with no repeats.

DROP FUNCTION IF EXISTS public.current_cycle_info(uuid, date);

CREATE FUNCTION public.current_cycle_info(p_agency_id uuid, p_today date DEFAULT NULL::date)
RETURNS TABLE(
  cycle_start                date,
  cycle_end                  date,
  week_of_cycle              integer,
  week_ending_saturday       date,
  prior_week_ending_saturday date,
  weeks_in_cycle             integer,
  quarter_number             integer,
  quarter_year               integer,
  quarter_label              text
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_anchor       date;
  v_today        date;
  v_cycles       int;
  v_cycle_start  date;
  v_week         int;
  v_mid          date;
BEGIN
  v_today := COALESCE(p_today, (now() AT TIME ZONE 'America/Chicago')::date);

  SELECT setting_value::date INTO v_anchor
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'cycle_anchor_date';
  IF v_anchor IS NULL THEN v_anchor := '2026-04-05'::date; END IF;

  -- floor, not truncate: dates before the anchor must land in the earlier cycle
  v_cycles      := floor((v_today - v_anchor) / 91.0)::int;
  v_cycle_start := v_anchor + (v_cycles * 91);
  v_week        := ((v_today - v_cycle_start) / 7) + 1;   -- always 1..13 after the floor
  v_mid         := v_cycle_start + 45;

  cycle_start                := v_cycle_start;
  cycle_end                  := v_cycle_start + 90;       -- 91 days = 13 weeks, Sun..Sat
  week_of_cycle              := v_week;
  week_ending_saturday       := v_cycle_start + (v_week * 7) - 1;
  prior_week_ending_saturday := week_ending_saturday - 7;
  weeks_in_cycle             := 13;                       -- always. Not derived, not variable.
  quarter_number             := EXTRACT(QUARTER FROM v_mid)::int;
  quarter_year               := EXTRACT(YEAR    FROM v_mid)::int;
  quarter_label              := 'Q' || quarter_number::text || ' ' || quarter_year::text;

  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.current_cycle_info(uuid, date) IS
'THE single source of quarter boundaries. Quarters are 13 weeks (91 days), Sunday start, closing on the last Saturday, stepped from settings.cycle_anchor_date. Peter directive 2026-08-28. Also returns the quarter label (from the cycle midpoint) so no caller ever derives a quarter name itself. Nothing else in the system may compute a quarter boundary or a quarter name.';

GRANT EXECUTE ON FUNCTION public.current_cycle_info(uuid, date) TO anon, authenticated;
