-- Two helpers for the rolling 13-week Sales Points avg.
-- Data source: weekly_cpr_team_detail.sales_points joined to weekly_cpr_reports.week_ending_date.
-- Both return NULL if no weekly detail rows exist in the window (graceful degradation).

-- Per-team-member: simple avg of that person's sales_points across last 13 weeks ending on/before reference date.
CREATE OR REPLACE FUNCTION public.team_member_sales_points_avg_13wk(
  p_team_member_id uuid,
  p_end_date       date DEFAULT CURRENT_DATE
)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT AVG(td.sales_points)::numeric
  FROM public.weekly_cpr_team_detail td
  JOIN public.weekly_cpr_reports r ON r.id = td.weekly_cpr_report_id
  WHERE td.team_member_id = p_team_member_id
    AND r.week_ending_date <= p_end_date
    AND r.week_ending_date >  p_end_date - INTERVAL '91 days';   -- 13 weeks
$$;

-- Agency-wide: avg per-team-member-per-week sales_points across the last 13 weeks.
-- Mathematically equivalent to (sum across all rows) ÷ (count of rows). For a team of N people
-- each producing $X/week consistently, this returns $X — i.e., it measures per-AM pace, not a
-- summed total. Matches the band semantics ($1000 = Good for one AM-week of work).
CREATE OR REPLACE FUNCTION public.agency_sales_points_avg_13wk(
  p_agency_id uuid,
  p_end_date  date DEFAULT CURRENT_DATE
)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT AVG(td.sales_points)::numeric
  FROM public.weekly_cpr_team_detail td
  JOIN public.weekly_cpr_reports r ON r.id = td.weekly_cpr_report_id
  WHERE r.agency_id = p_agency_id
    AND r.week_ending_date <= p_end_date
    AND r.week_ending_date >  p_end_date - INTERVAL '91 days';
$$;

GRANT EXECUTE ON FUNCTION public.team_member_sales_points_avg_13wk(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.agency_sales_points_avg_13wk(uuid, date) TO authenticated;
