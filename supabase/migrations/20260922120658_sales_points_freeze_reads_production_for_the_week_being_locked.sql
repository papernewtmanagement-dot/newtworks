CREATE OR REPLACE FUNCTION public.get_sales_points_qtd(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(team_id uuid, sales_points numeric, source text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_week_end date;
  v_cycle_start date;
  v_reported_through date;
  v_live boolean;
BEGIN
  SELECT c.week_ending_saturday, c.cycle_start INTO v_week_end, v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_end) c;

  v_reported_through := public.rp_reported_through(p_agency_id);
  -- A week reads from production until its number is frozen. The payroll lock
  -- row is written BEFORE the freeze trigger runs, so the week being locked
  -- must still count as live here, or the freeze copies last week's number
  -- forward and the week reads as zero (2026-09-19 bug).
  v_live := v_week_end > v_reported_through
         OR (v_week_end = v_reported_through AND NOT EXISTS (
               SELECT 1 FROM public.weekly_cpr_team_detail d
               JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
               WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_week_end
                 AND d.sales_points_frozen IS NOT NULL));

  RETURN QUERY
  WITH frozen AS (
    SELECT d.team_member_id AS tm, d.sales_points_frozen AS pts
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date = v_week_end
      AND d.sales_points_frozen IS NOT NULL
  ),
  production AS (
    SELECT r.team_member_id AS tm,
           COALESCE((ps.sp->'commission'->>'total_commission')::numeric, 0) AS pts
    FROM public.rp_board_roster_for(p_agency_id, v_week_end) r
    LEFT JOIN public.production_sales_points_for(p_agency_id, v_cycle_start, v_week_end) ps
      ON ps.team_member_id = r.team_member_id
    WHERE v_live
  ),
  override AS (
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
    SELECT tm FROM frozen
    UNION SELECT tm FROM production
    UNION SELECT tm FROM override
    UNION SELECT tm FROM reported
  )
  SELECT e.tm,
         COALESCE(f.pts, pr.pts, o.pts, rp.pts, 0)::numeric,
         CASE WHEN f.pts  IS NOT NULL THEN 'frozen'
              WHEN pr.pts IS NOT NULL THEN 'production'
              WHEN o.pts  IS NOT NULL THEN 'cpr_override'
              WHEN rp.pts IS NOT NULL THEN 'self_reported'
              ELSE 'none' END
  FROM everyone e
  LEFT JOIN frozen f ON f.tm = e.tm
  LEFT JOIN production pr ON pr.tm = e.tm
  LEFT JOIN override o ON o.tm = e.tm
  LEFT JOIN reported rp ON rp.tm = e.tm;
END;
$function$;
