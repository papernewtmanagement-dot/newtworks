-- One-person lookup on top of the resolver, so readers stop reaching into
-- weekly_cpr_team_detail.sales_points (Peter's typed override) as if it were the
-- whole answer. Returns the source too, so a caller can tell a real zero from
-- no history at all.
CREATE OR REPLACE FUNCTION public.sales_points_qtd_for(p_agency_id uuid, p_week_end date, p_team_member_id uuid)
RETURNS TABLE(sales_points numeric, source text)
LANGUAGE sql STABLE
SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT COALESCE(g.sales_points, 0)::numeric, COALESCE(g.source, 'none')::text
  FROM (SELECT 1) z
  LEFT JOIN public.get_sales_points_qtd(p_agency_id, p_week_end) g
    ON g.team_id = p_team_member_id;
$fn$;

COMMENT ON FUNCTION public.sales_points_qtd_for(uuid, date, uuid) IS
'Quarter-to-date sales points for one person for one week, from get_sales_points_qtd. Use this instead of reading weekly_cpr_team_detail.sales_points.';

-- Points earned in the last four weeks.
CREATE OR REPLACE FUNCTION public.compute_rolling_4wk_sp(p_agency_id uuid, p_week_end_date date, p_team_member_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_q_start        date;
  v_prior_end      date;
  v_weeks_elapsed  int;
  v_curr_qtd       numeric := 0;
  v_qtd_minus_4    numeric := 0;
  v_prior_q_total  numeric := 0;
  v_src            text;
BEGIN
  v_q_start := (SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci);
  v_weeks_elapsed := ((p_week_end_date - v_q_start) / 7) + 1;

  SELECT f.sales_points INTO v_curr_qtd
  FROM public.sales_points_qtd_for(p_agency_id, p_week_end_date, p_team_member_id) f;
  v_curr_qtd := COALESCE(v_curr_qtd, 0);

  IF v_weeks_elapsed >= 4 THEN
    IF (p_week_end_date - 28) >= v_q_start THEN
      SELECT f.sales_points INTO v_qtd_minus_4
      FROM public.sales_points_qtd_for(p_agency_id, (p_week_end_date - 28), p_team_member_id) f;
    END IF;
    v_qtd_minus_4 := COALESCE(v_qtd_minus_4, 0);
    RETURN GREATEST(0, v_curr_qtd - v_qtd_minus_4);
  END IF;

  -- Early in a cycle there are not four weeks to look back on, so borrow a share
  -- of the prior cycle's closing total.
  SELECT cci.cycle_end INTO v_prior_end
  FROM public.current_cycle_info(p_agency_id, v_q_start - 1) cci;

  IF v_prior_end IS NOT NULL THEN
    SELECT f.sales_points, f.source INTO v_prior_q_total, v_src
    FROM public.sales_points_qtd_for(p_agency_id, v_prior_end, p_team_member_id) f;
    IF v_src = 'none' THEN v_prior_q_total := 0; END IF;
  END IF;
  v_prior_q_total := COALESCE(v_prior_q_total, 0);

  RETURN GREATEST(0, v_curr_qtd + ((4 - v_weeks_elapsed)::numeric / 13.0) * v_prior_q_total);
END;
$fn$;

-- Average weekly sales points over the last N weeks.
CREATE OR REPLACE FUNCTION public.team_member_sales_points_avg_nwk(p_team_member_id uuid, p_n_weeks integer, p_end_date date DEFAULT CURRENT_DATE)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $fn$
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
$fn$;
