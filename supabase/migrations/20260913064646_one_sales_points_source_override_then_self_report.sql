-- Peter 2026-09-12: ONE function pulls sales points. Nothing else may compute them.
-- Order: the manual override on the CPR first, then the team's own reported number.
-- Quarter to date, so each person's figure is the latest one that exists on or
-- before the week asked for. Someone who left mid-quarter keeps their last figure
-- (John, week ending 2026-09-05, 1454.98) instead of dropping out of the total.
-- The Production tables are NOT a source here. From the go-live week they become
-- one, and that gets added to this function and nowhere else.
CREATE OR REPLACE FUNCTION public.get_sales_points_qtd(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(team_id uuid, sales_points numeric, source text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_week_end date;
  v_cycle_start date;
BEGIN
  SELECT c.week_ending_saturday, c.cycle_start INTO v_week_end, v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_end) c;

  RETURN QUERY
  WITH override AS (
    SELECT DISTINCT ON (d.team_member_id)
      d.team_member_id AS tm, d.sales_points AS pts
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date BETWEEN v_cycle_start AND v_week_end
      AND d.sales_points IS NOT NULL
    ORDER BY d.team_member_id, r.week_ending_date DESC
  ),
  reported AS (
    SELECT DISTINCT ON (tc.team_id)
      tc.team_id AS tm, tc.sales_points_quarter AS pts
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_cycle_start AND v_week_end
      AND tc.sales_points_quarter IS NOT NULL
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ),
  everyone AS (
    SELECT tm FROM override UNION SELECT tm FROM reported
  )
  SELECT e.tm,
         COALESCE(o.pts, rp.pts, 0)::numeric,
         CASE WHEN o.pts IS NOT NULL THEN 'cpr_override'
              WHEN rp.pts IS NOT NULL THEN 'self_reported'
              ELSE 'none' END
  FROM everyone e
  LEFT JOIN override o ON o.tm = e.tm
  LEFT JOIN reported rp ON rp.tm = e.tm;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_sales_points_qtd(uuid, date) TO anon, authenticated, service_role;

-- Win the Week now reads the one function for sales points. Quotes are unchanged.
CREATE OR REPLACE FUNCTION public.get_team_checkin_totals(p_agency_id uuid, p_period_start date, p_period_end date)
 RETURNS TABLE(total_quotes numeric, total_sales_points numeric)
 LANGUAGE sql
 STABLE
AS $function$
  SELECT
    (SELECT COALESCE(SUM(latest_q), 0)
     FROM (
       SELECT DISTINCT ON (tc.team_id) tc.quotes_week AS latest_q
       FROM public.team_checkins tc
       WHERE tc.agency_id = p_agency_id
         AND tc.checkin_date BETWEEN p_period_start AND p_period_end
       ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
     ) q) AS total_quotes,
    (SELECT COALESCE(SUM(s.sales_points), 0)
     FROM public.get_sales_points_qtd(p_agency_id, p_period_end) s) AS total_sales_points;
$function$;
