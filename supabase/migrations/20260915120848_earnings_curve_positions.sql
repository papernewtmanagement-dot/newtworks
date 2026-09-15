-- Where each person actually sits on the Earnings chart.
--
-- One marker per seat. x is the same 13-week weekly sales-points average the
-- Sales Points rating runs on, read straight out of
-- public.team_sales_points_ratings so there is exactly one copy of that maths.
--
-- The chart's x axis is raw weekly sales points on both the Sales curve and
-- the Retention curve (the Retention curve carries its own band thresholds,
-- built off a 50-point weekly target rather than 100), so the raw average is
-- the right figure for both. rel_13wk is deliberately NOT used here: it exists
-- only to rate a Retention seat against the Sales band scale.
--
-- Scope: an admin (owner or manager) gets the whole team, anyone else gets
-- their own marker and nobody else's.
--
-- Computed at request time, nothing stored -- core_principles 650.
CREATE OR REPLACE FUNCTION public.earnings_curve_positions(p_agency_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(m ORDER BY m->>'first_name'), '[]'::jsonb)
    FROM (
      SELECT jsonb_build_object(
               'team_member_id', r.team_member_id,
               'first_name',     r.first_name,
               'is_me',          r.team_member_id = public.current_team_member_id(),
               'role_key',       lower(r.role_category),
               'x',              r.avg_13wk,
               'rating',         r.rating,
               'weeks_employed', r.weeks_employed
             ) AS m
        FROM public.team_sales_points_ratings(p_agency_id) r
       WHERE r.avg_13wk IS NOT NULL
         AND lower(COALESCE(r.role_category, '')) IN ('sales', 'retention')
         AND (public.is_agency_admin()
              OR r.team_member_id = public.current_team_member_id())
    ) s;
$function$;

GRANT EXECUTE ON FUNCTION public.earnings_curve_positions(uuid) TO authenticated;
