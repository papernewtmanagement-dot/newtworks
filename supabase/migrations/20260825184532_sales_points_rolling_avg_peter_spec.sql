-- Rolling Sales Points average, per Peter's spec (2026-08-24). Replaces the
-- plan-floor approach from 20260824234100, which was built on a wrong premise
-- (it assumed pre-2026-07-11 sales_points were old-scale; they are NOT --
-- migration 20260709045032 rescaled prior quarters into the canonical column
-- and parked the old activity-based values in sales_points_v01).
--
-- SPEC:
--   current_points = stored quarter-to-date sales points for the current cycle
--   gap_weeks      = N - week_of_cycle   (N = 13 or 39)
--   gap_points     = points earned in the gap_weeks weeks immediately before
--                    the current cycle started, walking back through prior
--                    cycles: a whole prior cycle contributes its stored close
--                    total; a partial one contributes close - cum[13 - take],
--                    reconstructed by sp_walk_quarter scaled to that close total.
--   average        = (current_points + gap_points) / N
--
-- Cycle boundaries and week_of_cycle come from current_cycle_info -- never
-- from calendar-quarter math, which is off by a week (calendar Q2 close row
-- sits on 2026-06-27; the cycle actually ends 2026-07-04).
--
-- Prior-quarter average for pay review = close total / 13, which this returns
-- naturally when week_of_cycle = 13.

CREATE OR REPLACE FUNCTION public.team_member_sales_points_avg_nwk(
  p_team_member_id uuid,
  p_n_weeks        integer,
  p_end_date       date DEFAULT CURRENT_DATE
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_agency      uuid;
  v_cycle       record;
  v_prior       record;
  v_current     numeric;
  v_close       numeric;
  v_cum         numeric;
  v_total       numeric := 0;
  v_gap_weeks   integer;
  v_take        integer;
  v_scan_start  date;
  v_guard       integer := 0;
BEGIN
  IF p_n_weeks IS NULL OR p_n_weeks <= 0 THEN RETURN NULL; END IF;

  SELECT agency_id INTO v_agency FROM public.team WHERE id = p_team_member_id;
  IF v_agency IS NULL THEN RETURN NULL; END IF;

  SELECT * INTO v_cycle FROM public.current_cycle_info(v_agency, p_end_date);
  IF v_cycle.cycle_start IS NULL THEN RETURN NULL; END IF;

  -- current_points: latest stored quarter-to-date value inside this cycle
  SELECT td.sales_points INTO v_current
  FROM public.weekly_cpr_team_detail td
  JOIN public.weekly_cpr_reports r ON r.id = td.weekly_cpr_report_id
  WHERE td.team_member_id  = p_team_member_id
    AND r.week_ending_date >= v_cycle.cycle_start
    AND r.week_ending_date <= p_end_date
    AND td.sales_points IS NOT NULL
  ORDER BY r.week_ending_date DESC
  LIMIT 1;

  v_total      := COALESCE(v_current, 0);
  v_gap_weeks  := p_n_weeks - v_cycle.week_of_cycle;
  v_scan_start := v_cycle.cycle_start;

  WHILE v_gap_weeks > 0 AND v_guard < 20 LOOP
    v_guard := v_guard + 1;

    SELECT * INTO v_prior FROM public.current_cycle_info(v_agency, v_scan_start - 1);
    EXIT WHEN v_prior.cycle_start IS NULL;

    -- stored close total for that cycle (the quarter-close backfill row)
    SELECT MAX(td.sales_points) INTO v_close
    FROM public.weekly_cpr_team_detail td
    JOIN public.weekly_cpr_reports r ON r.id = td.weekly_cpr_report_id
    WHERE td.team_member_id  = p_team_member_id
      AND r.week_ending_date >= v_prior.cycle_start
      AND r.week_ending_date <= v_prior.cycle_end
      AND td.sales_points IS NOT NULL;

    EXIT WHEN v_close IS NULL;  -- no history that far back; stop, don't invent

    v_take := LEAST(v_gap_weeks, 13);

    IF v_take >= 13 THEN
      v_total := v_total + v_close;
    ELSE
      -- points earned in the LAST v_take weeks of that cycle
      SELECT w.sales_points_cum INTO v_cum
      FROM public.sp_walk_quarter(v_agency, p_team_member_id,
                                  v_prior.cycle_start + 7, v_close) w
      WHERE w.week_no = 13 - v_take;
      v_total := v_total + (v_close - COALESCE(v_cum, 0));
    END IF;

    v_gap_weeks  := v_gap_weeks - v_take;
    v_scan_start := v_prior.cycle_start;
  END LOOP;

  RETURN ROUND(v_total / p_n_weeks, 2);
END;
$function$;

CREATE OR REPLACE FUNCTION public.team_member_sales_points_avg_13wk(p_team_member_id uuid, p_end_date date DEFAULT CURRENT_DATE)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$ SELECT public.team_member_sales_points_avg_nwk(p_team_member_id, 13, p_end_date); $function$;

CREATE OR REPLACE FUNCTION public.team_member_sales_points_avg_39wk(p_team_member_id uuid, p_end_date date DEFAULT CURRENT_DATE)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$ SELECT public.team_member_sales_points_avg_nwk(p_team_member_id, 39, p_end_date); $function$;

CREATE OR REPLACE FUNCTION public.agency_sales_points_avg_13wk(p_agency_id uuid, p_end_date date DEFAULT CURRENT_DATE)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  SELECT ROUND(SUM(public.team_member_sales_points_avg_nwk(t.id, 13, p_end_date)), 2)
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND t.is_active
    AND COALESCE(t.is_test_user, false) = false;
$function$;

COMMENT ON FUNCTION public.team_member_sales_points_avg_nwk(uuid, integer, date) IS
  'Rolling N-week Sales Points average per Peter spec 2026-08-24: (current cycle QTD + points earned in the (N - week_of_cycle) weeks before this cycle started) / N. Cycle boundaries from current_cycle_info. Partial prior cycles reconstructed by sp_walk_quarter scaled to that cycle stored close total. 13 = gain check, 39 = raise review.';
