-- Where each person actually sits on the Earnings chart: one point per seat.
--
-- x is the 13-week weekly sales-points average, from
-- public.team_member_sales_points_avg_13wk -- the one copy of that maths. The
-- chart's x axis is raw weekly sales points on both the Sales and the
-- Retention curve, so the raw average is right for both.
--
-- y is on-time annual pay, from public.team_on_time_annual_pay. That is the
-- SAME function the weekly CPR's OT Annual row reads, so the two can no longer
-- disagree. The thinner pay sum this function used to carry has been deleted.
--
-- Roster: every agency seat on a Sales or Retention curve, licensed or not. An
-- unlicensed seat produces no sales points and simply sits at zero on the
-- production axis with its real pay -- it is not hidden.
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
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'team_member_id', s.id,
           'first_name',     s.first_name,
           'is_me',          s.id = public.current_team_member_id(),
           'role_key',       lower(s.role_category),
           'x',              s.avg_13wk,
           'y',              p.on_time_annual,
           'ytd_paid',       p.ytd_paid,
           'as_of_week',     p.week_ending_date
         ) ORDER BY s.first_name), '[]'::jsonb)
    FROM (
      SELECT t.id,
             t.first_name,
             t.role_category,
             public.team_member_sales_points_avg_13wk(t.id) AS avg_13wk
        FROM public.team t
       WHERE t.agency_id                  = p_agency_id
         AND t.category                   = 'agency'
         AND COALESCE(t.role_level, '')  <> 'Owner'
         AND t.archived_at IS NULL
         AND t.is_test_user IS NOT TRUE
         AND lower(COALESCE(t.role_category, '')) IN ('sales', 'retention')
         AND (public.is_agency_admin()
              OR t.id = public.current_team_member_id())
    ) s
    LEFT JOIN public.team_on_time_annual_pay(p_agency_id) p
      ON p.team_member_id = s.id
   WHERE s.avg_13wk IS NOT NULL;
$function$;

GRANT EXECUTE ON FUNCTION public.earnings_curve_positions(uuid) TO authenticated;
