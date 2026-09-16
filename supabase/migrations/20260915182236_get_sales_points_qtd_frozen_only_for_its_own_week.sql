-- Tightening the freeze precedence. A frozen figure applies to ITS OWN week only.
-- It must never carry forward into a later, still-open week: once Production becomes a
-- source, a live week has to be free to compute, and an unsent week inheriting a frozen
-- value from the last sent week would block it and mislabel the source as 'frozen'.
-- Precedence per person: this week's frozen figure -> Peter's typed override carried
-- forward from the latest week in the cycle -> self-reported check-in.
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
  WITH frozen AS (
    -- Only the row for this exact week. A sent week keeps the number the team was
    -- paid on, whatever lands in the production log afterwards.
    SELECT d.team_member_id AS tm, d.sales_points_frozen AS pts
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date = v_week_end
      AND d.sales_points_frozen IS NOT NULL
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
    SELECT tm FROM frozen UNION SELECT tm FROM override UNION SELECT tm FROM reported
  )
  SELECT e.tm,
         COALESCE(f.pts, o.pts, rp.pts, 0)::numeric,
         CASE WHEN f.pts  IS NOT NULL THEN 'frozen'
              WHEN o.pts  IS NOT NULL THEN 'cpr_override'
              WHEN rp.pts IS NOT NULL THEN 'self_reported'
              ELSE 'none' END
  FROM everyone e
  LEFT JOIN frozen f ON f.tm = e.tm
  LEFT JOIN override o ON o.tm = e.tm
  LEFT JOIN reported rp ON rp.tm = e.tm;
END;
$function$;
