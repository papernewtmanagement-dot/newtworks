-- Where each person actually sits on the Earnings chart: one point, read off
-- both axes.
--
-- x is the 13-week weekly sales-points average, read straight out of
-- public.team_sales_points_ratings so there is exactly one copy of that maths.
-- The chart's x axis is raw weekly sales points on both the Sales curve and
-- the Retention curve, so the raw average is the right figure for both.
-- rel_13wk is deliberately NOT used: it exists only to rate a Retention seat
-- against the Sales band scale.
--
-- y is ACTUAL pay, not a projection: real dollars paid year to date
-- (weekly_cpr_team_detail.payroll_ytd_paid on the most recent week that
-- carries one), put on an annual pace. The pace divides by the weeks the
-- person has actually been on payroll this year, counted from their hire date
-- when they started mid-year, so a February hire is not made to look
-- underpaid against a full calendar year.
--
-- Scope: an admin (owner or manager) gets the whole team, anyone else gets
-- their own point and nobody else's.
--
-- Computed at request time, nothing stored -- core_principles 650.
CREATE OR REPLACE FUNCTION public.earnings_curve_positions(p_agency_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH latest AS (
    SELECT DISTINCT ON (d.team_member_id)
           d.team_member_id,
           r.week_ending_date,
           d.payroll_ytd_paid
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
     WHERE d.agency_id = p_agency_id
       AND d.payroll_ytd_paid IS NOT NULL
       AND r.week_ending_date >= date_trunc('year',
             (now() AT TIME ZONE 'America/Chicago')::date)::date
     ORDER BY d.team_member_id, r.week_ending_date DESC
  ),
  seat AS (
    SELECT s.team_member_id,
           s.first_name,
           s.role_category,
           s.avg_13wk,
           s.rating,
           s.weeks_employed,
           l.week_ending_date,
           l.payroll_ytd_paid,
           GREATEST(
             (l.week_ending_date - GREATEST(
                date_trunc('year', l.week_ending_date)::date,
                COALESCE(t.hire_date, date_trunc('year', l.week_ending_date)::date)
             ))::numeric / 7.0,
             1) AS weeks_counted
      FROM public.team_sales_points_ratings(p_agency_id) s
      JOIN public.team t ON t.id = s.team_member_id
      LEFT JOIN latest l ON l.team_member_id = s.team_member_id
     WHERE s.avg_13wk IS NOT NULL
       AND lower(COALESCE(s.role_category, '')) IN ('sales', 'retention')
       AND (public.is_agency_admin()
            OR s.team_member_id = public.current_team_member_id())
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'team_member_id', s.team_member_id,
           'first_name',     s.first_name,
           'is_me',          s.team_member_id = public.current_team_member_id(),
           'role_key',       lower(s.role_category),
           'x',              s.avg_13wk,
           'y',              CASE WHEN s.payroll_ytd_paid IS NULL THEN NULL
                                  ELSE round(s.payroll_ytd_paid / s.weeks_counted * 52, 0) END,
           'ytd_paid',       s.payroll_ytd_paid,
           'weeks_counted',  round(s.weeks_counted, 1),
           'as_of_week',     s.week_ending_date,
           'rating',         s.rating,
           'weeks_employed', s.weeks_employed
         ) ORDER BY s.first_name), '[]'::jsonb)
    FROM seat s;
$function$;

GRANT EXECUTE ON FUNCTION public.earnings_curve_positions(uuid) TO authenticated;
