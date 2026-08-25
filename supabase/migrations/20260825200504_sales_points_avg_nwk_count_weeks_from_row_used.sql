-- Fix: mid-week undercount in the rolling Sales Points average.
--
-- current_cycle_info.week_of_cycle counts the in-progress week from Sunday, but
-- current_points can only hold the last COMPLETED Saturday. So Sunday-Friday the
-- function summed 12 weeks of points and divided by 13 (a 7.7% understatement).
-- Verified live 2026-08-25 (Tue): agency avg 109.54 on Sat 08-22 -> 99.31 today
-- with zero new production, which flipped both sales seats under the
-- unlimited-time-off gate (time_off_check_eligibility) by arithmetic alone.
--
-- Peter's spec is unchanged: average = (current_points + gap_points) / N.
-- The only change: gap_weeks = N - (weeks covered by the row actually used),
-- where weeks covered = week number, within the cycle, of that row's Saturday.
-- On a Saturday this equals week_of_cycle exactly; on other days it is exact
-- instead of one week short. No row yet this cycle -> 0 weeks covered ->
-- the whole prior quarter's close total / N (i.e. the prior-quarter average).

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
  v_agency        uuid;
  v_cycle         record;
  v_prior         record;
  v_current       numeric;
  v_current_week  date;
  v_weeks_covered integer;
  v_close         numeric;
  v_cum           numeric;
  v_total         numeric := 0;
  v_gap_weeks     integer;
  v_take          integer;
  v_scan_start    date;
  v_guard         integer := 0;
BEGIN
  IF p_n_weeks IS NULL OR p_n_weeks <= 0 THEN RETURN NULL; END IF;

  SELECT agency_id INTO v_agency FROM public.team WHERE id = p_team_member_id;
  IF v_agency IS NULL THEN RETURN NULL; END IF;

  SELECT * INTO v_cycle FROM public.current_cycle_info(v_agency, p_end_date);
  IF v_cycle.cycle_start IS NULL THEN RETURN NULL; END IF;

  -- current_points: latest stored quarter-to-date value inside this cycle,
  -- and the Saturday it belongs to (only completed weeks: week_ending <= p_end_date)
  SELECT td.sales_points, r.week_ending_date
    INTO v_current, v_current_week
  FROM public.weekly_cpr_team_detail td
  JOIN public.weekly_cpr_reports r ON r.id = td.weekly_cpr_report_id
  WHERE td.team_member_id  = p_team_member_id
    AND r.week_ending_date >= v_cycle.cycle_start
    AND r.week_ending_date <= p_end_date
    AND td.sales_points IS NOT NULL
  ORDER BY r.week_ending_date DESC
  LIMIT 1;

  v_total := COALESCE(v_current, 0);

  -- weeks of this cycle actually represented by that row (0 if none yet)
  v_weeks_covered := CASE
    WHEN v_current_week IS NULL THEN 0
    ELSE ((v_current_week - v_cycle.cycle_start) / 7) + 1
  END;

  v_gap_weeks  := p_n_weeks - v_weeks_covered;
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
