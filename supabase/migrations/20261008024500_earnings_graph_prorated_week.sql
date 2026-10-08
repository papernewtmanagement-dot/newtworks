-- Earnings graph moves through the week (Peter 2026-10-07): optional prorated read.
DROP FUNCTION public.team_raise_progress(uuid, date);
DROP FUNCTION public.team_member_sales_points_avg_nwk(uuid, integer, date);
CREATE OR REPLACE FUNCTION public.team_member_sales_points_avg_nwk(p_team_member_id uuid, p_n_weeks integer, p_end_date date DEFAULT CURRENT_DATE, p_prorate boolean DEFAULT false)
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
  v_base          numeric;
  v_open_week     date;
  v_frac          numeric;
  v_now           numeric;
  v_prev          numeric;
BEGIN
  IF p_n_weeks IS NULL OR p_n_weeks <= 0 THEN RETURN NULL; END IF;

  -- Prorated read (Peter 2026-10-07, Earnings graph only): the finished-weeks average
  -- plus the open week's points so far, the open week counted as the share of its
  -- five weekdays already elapsed. Raise reviews never pass p_prorate.
  IF p_prorate THEN
    v_base := public.team_member_sales_points_avg_nwk(p_team_member_id, p_n_weeks, p_end_date, false);
    v_open_week := public.rp_week_end(p_end_date);
    IF v_base IS NULL OR v_open_week <= p_end_date THEN RETURN v_base; END IF;
    v_frac := LEAST(5, EXTRACT(DOW FROM p_end_date)::int) / 5.0;
    IF v_frac <= 0 THEN RETURN v_base; END IF;
    SELECT agency_id INTO v_agency FROM public.team WHERE id = p_team_member_id;
    SELECT * INTO v_cycle FROM public.current_cycle_info(v_agency, p_end_date);
    SELECT f.sales_points INTO v_now FROM public.sales_points_qtd_for(v_agency, v_open_week, p_team_member_id) f;
    IF v_open_week - 7 >= v_cycle.cycle_start THEN
      SELECT f.sales_points INTO v_prev FROM public.sales_points_qtd_for(v_agency, v_open_week - 7, p_team_member_id) f;
    END IF;
    RETURN ROUND((v_base * p_n_weeks + COALESCE(v_now, 0) - COALESCE(v_prev, 0)) / (p_n_weeks + v_frac), 2);
  END IF;

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

CREATE OR REPLACE FUNCTION public.team_raise_progress(p_agency_id uuid, p_as_of date DEFAULT CURRENT_DATE, p_prorate boolean DEFAULT false)
 RETURNS TABLE(team_member_id uuid, first_name text, role_category text, role_level text, weeks_employed integer, current_hourly numeric, title_increment numeric, tier_hourly numeric, current_tier integer, next_tier integer, next_hourly numeric, next_requirement text, next_threshold numeric, lookback_quarters integer, avg_weekly_sp numeric, points_to_go numeric, on_track boolean, at_top boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
SELECT public.require_login('staff');
  WITH seats AS (
    SELECT t.id, t.first_name, t.role_category, t.role_level,
           COALESCE(t.license_pc,false) AS has_pc, COALESCE(t.license_lh,false) AS has_lh,
           CASE WHEN t.hire_date IS NULL THEN 0
                ELSE FLOOR((p_as_of - t.hire_date) / 7.0)::integer END AS weeks_employed,
           CASE WHEN UPPER(COALESCE(t.pay_type,'')) = 'SALARY'
                THEN t.pay_rate / 40.0 ELSE t.pay_rate END AS hourly,
           CASE WHEN t.role_category = 'Retention' THEN 0.5 ELSE 1.0 END AS req_weight,
           COALESCE((SELECT s.base_hourly FROM public.pay_scale s
                      WHERE s.agency_id = p_agency_id AND s.role_key = 'title_step'
                        AND s.title_label = t.role_level LIMIT 1), 0) AS title_inc
      FROM public.team t
     WHERE t.agency_id = p_agency_id AND t.category = 'agency'
       AND COALESCE(t.role_level,'') <> 'Owner'
       AND t.is_active = true AND t.archived_at IS NULL AND t.is_test_user IS NOT TRUE
       AND t.pay_rate IS NOT NULL
  ),
  placed AS (
    SELECT s.*, (s.hourly - s.title_inc) AS tier_rate,
           (SELECT p.raise_tier FROM public.pay_scale p
             WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
               AND p.tier_starts_here AND p.base_hourly <= (s.hourly - s.title_inc)
             ORDER BY p.base_hourly DESC LIMIT 1) AS cur_tier
      FROM seats s
  ),
  nxt AS (
    SELECT pl.*, n.raise_tier AS nx_tier, n.base_hourly AS nx_hourly,
           n.sales_points AS nx_threshold, n.lookback_quarters AS nx_lookback,
           n.retention_requirement AS nx_req, n.retention_requires_pc AS nx_pc,
           n.retention_requires_lh AS nx_lh
      FROM placed pl
      LEFT JOIN LATERAL (
        SELECT p.raise_tier, p.base_hourly, p.sales_points, p.lookback_quarters,
               p.retention_requirement, p.retention_requires_pc, p.retention_requires_lh
          FROM public.pay_scale p
         WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
           AND p.raise_tier > COALESCE(pl.cur_tier, -1)
           -- Retention climbs the licence steps; everyone else the pace ladder.
           AND (pl.role_category IS DISTINCT FROM 'Retention'
                OR (p.retention_requirement IS NOT NULL
                    AND NOT ((pl.has_pc OR NOT COALESCE(p.retention_requires_pc, false))
                         AND (pl.has_lh OR NOT COALESCE(p.retention_requires_lh, false)))))
         ORDER BY p.raise_tier LIMIT 1
      ) n ON true
  )
  SELECT x.id, x.first_name, x.role_category, x.role_level, x.weeks_employed,
         ROUND(x.hourly, 2), x.title_inc, ROUND(x.tier_rate, 2),
         x.cur_tier, x.nx_tier, x.nx_hourly + x.title_inc,
         CASE WHEN x.role_category = 'Retention' THEN x.nx_req
              WHEN x.nx_threshold IS NULL THEN NULL
              ELSE x.nx_threshold::text || ' a week averaged over the last ' || x.nx_lookback
                   || CASE WHEN x.nx_lookback = 1 THEN ' quarter' ELSE ' quarters' END END,
         CASE WHEN x.role_category = 'Retention' THEN NULL ELSE x.nx_threshold END,
         CASE WHEN x.role_category = 'Retention' THEN NULL ELSE x.nx_lookback END,
         x.avg_sp,
         CASE WHEN x.role_category = 'Retention' OR x.nx_threshold IS NULL OR x.avg_sp IS NULL
              THEN NULL ELSE GREATEST(ROUND(x.nx_threshold - x.avg_sp, 1), 0) END,
         CASE WHEN x.nx_tier IS NULL THEN false
              WHEN x.role_category = 'Retention'
                THEN (x.has_pc OR NOT COALESCE(x.nx_pc,false))
                 AND (x.has_lh OR NOT COALESCE(x.nx_lh,false))
              WHEN x.nx_threshold IS NULL OR x.avg_sp IS NULL THEN false
              ELSE x.avg_sp >= x.nx_threshold END,
         (x.nx_tier IS NULL)
    FROM (
      SELECT n.*,
             CASE WHEN n.role_category = 'Retention' OR n.nx_lookback IS NULL THEN NULL
                  ELSE ROUND(public.team_member_sales_points_avg_nwk(
                         n.id, n.nx_lookback * 13, p_as_of, p_prorate) / n.req_weight, 2) END AS avg_sp
        FROM nxt n
    ) x
   ORDER BY x.first_name;
$function$;

REVOKE ALL ON FUNCTION public.team_member_sales_points_avg_nwk(uuid, integer, date, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.team_raise_progress(uuid, date, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.team_member_sales_points_avg_nwk(uuid, integer, date, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.team_raise_progress(uuid, date, boolean) TO authenticated, service_role;
