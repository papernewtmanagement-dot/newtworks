-- A window shorter than the quarter-to-date (n < weeks already covered this cycle) used to
-- return the WHOLE quarter-to-date divided by n, overstating the average (Stephanie, 3 weeks
-- to 2026-10-03: 151.27 instead of 42.44). Now only the last n weeks count. Callers that pass
-- 13 or more weeks, or weeks since hire, get the same numbers as before.
DO $guard$
BEGIN
  IF (SELECT md5(pg_get_functiondef('public.team_member_sales_points_avg_nwk(uuid,integer,date)'::regprocedure)))
     <> 'f3b7dc5d8b495b8bac7a5477aa47f988' THEN
    RAISE EXCEPTION 'team_member_sales_points_avg_nwk changed since it was read; re-read before replacing it';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.team_member_sales_points_avg_nwk(p_team_member_id uuid, p_n_weeks integer, p_end_date date DEFAULT CURRENT_DATE)
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
  v_close_src     text;
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

  -- Last COMPLETED week in this cycle. A week that has not finished yet does not
  -- carry a quarter-to-date figure for this purpose.
  v_current_week := public.rp_week_end(p_end_date);
  IF v_current_week > p_end_date THEN
    v_current_week := v_current_week - 7;
  END IF;
  IF v_current_week < v_cycle.cycle_start THEN
    v_current_week := NULL;
  END IF;

  IF v_current_week IS NOT NULL THEN
    SELECT f.sales_points INTO v_current
    FROM public.sales_points_qtd_for(v_agency, v_current_week, p_team_member_id) f;
  END IF;

  v_total := COALESCE(v_current, 0);

  v_weeks_covered := CASE
    WHEN v_current_week IS NULL THEN 0
    ELSE ((v_current_week - v_cycle.cycle_start) / 7) + 1
  END;

  -- Window shorter than this quarter so far: only the last p_n_weeks weeks count,
  -- so take the quarter-to-date as it stood p_n_weeks weeks ago off the current one.
  IF v_current_week IS NOT NULL AND v_weeks_covered > p_n_weeks THEN
    SELECT f.sales_points INTO v_close
    FROM public.sales_points_qtd_for(v_agency, v_current_week - 7 * p_n_weeks, p_team_member_id) f;
    RETURN ROUND((v_total - COALESCE(v_close, 0)) / p_n_weeks, 2);
  END IF;

  v_gap_weeks  := p_n_weeks - v_weeks_covered;
  v_scan_start := v_cycle.cycle_start;

  WHILE v_gap_weeks > 0 AND v_guard < 20 LOOP
    v_guard := v_guard + 1;

    SELECT * INTO v_prior FROM public.current_cycle_info(v_agency, v_scan_start - 1);
    EXIT WHEN v_prior.cycle_start IS NULL;

    SELECT f.sales_points, f.source INTO v_close, v_close_src
    FROM public.sales_points_qtd_for(v_agency, v_prior.cycle_end, p_team_member_id) f;

    EXIT WHEN v_close_src = 'none';  -- no history that far back; stop, don't invent

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

