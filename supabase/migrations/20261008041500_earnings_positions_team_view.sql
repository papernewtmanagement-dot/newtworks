CREATE OR REPLACE FUNCTION public.earnings_curve_positions(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Everyone sees every team point on their curve (Peter 2026-10-07, Team view toggle);
-- the gap stays admin-or-self inside raise_gap_scenario.
SELECT public.require_login('staff');
  -- Production on the chart is the same average the raise review measures
  -- (team_raise_progress): the look-back window of the person's next step. A seat with
  -- no pace step ahead (retention climbs on licences, or the top of the ladder) shows
  -- the four-quarter average, the window every step from the fourth on uses, shortened
  -- to time since hire so a newer teammate is not averaged over weeks before they started.
  -- Pay carries the manager title money separately so the label can show ladder step
  -- plus title (Peter 2026-10-03: the old 13-week figure did not match the raise rule).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'team_member_id',  s.id,
           'first_name',      s.first_name,
           'is_me',           s.id = public.current_team_member_id(),
           'role_key',        lower(s.role_category),
           'x',               s.avg_sp,
           'window_weeks',    s.window_wk,
           'y',               p.on_time_annual,
           'ytd_paid',        p.ytd_paid,
           'as_of_week',      p.week_ending_date,
           'current_hourly',  s.current_hourly,
           'step_hourly',     s.tier_hourly,
           'title_hourly',    s.title_increment,
           'title_label',     CASE WHEN COALESCE(s.title_increment,0) > 0 THEN s.role_level END,
           'next_hourly',     s.next_hourly,
           'next_step_hourly', s.next_hourly - COALESCE(s.title_increment, 0),
           'on_track',        COALESCE(s.on_track, false),
           'gap',             (SELECT g FROM jsonb_array_elements(gp.j) g WHERE g->>'team_member_id' = s.id::text LIMIT 1)
         ) ORDER BY s.first_name), '[]'::jsonb) || public.earnings_test_point(p_agency_id)
    FROM (
      SELECT t.id, t.first_name, t.role_category, t.role_level,
             rp.current_hourly, rp.tier_hourly, rp.title_increment, rp.next_hourly, rp.on_track,
             CASE WHEN lower(t.role_category) = 'retention'
                    THEN (SELECT r.weeks_counted FROM public.retention_raise_track(p_agency_id) r WHERE r.team_member_id = t.id)
                  WHEN rp.avg_weekly_sp IS NOT NULL THEN rp.lookback_quarters * 13
                  ELSE GREATEST(1, LEAST(52, COALESCE(rp.weeks_employed, 52))) END AS window_wk,
             CASE WHEN lower(t.role_category) = 'retention'
                  -- Retention chart's x is the retention track's weekly total points (2026-10-04).
                  THEN (SELECT r.avg_total_points FROM public.retention_raise_track(p_agency_id) r WHERE r.team_member_id = t.id)
             ELSE COALESCE(rp.avg_weekly_sp,
                      ROUND(public.team_member_sales_points_avg_nwk(
                        t.id, GREATEST(1, LEAST(52, COALESCE(rp.weeks_employed, 52))), CURRENT_DATE, true), 2)) END AS avg_sp
        FROM public.team t
        LEFT JOIN public.team_raise_progress(p_agency_id, CURRENT_DATE, true) rp ON rp.team_member_id = t.id
       WHERE t.agency_id                  = p_agency_id
         AND t.category                   = 'agency'
         AND COALESCE(t.role_level, '')  <> 'Owner'
         AND t.is_active = true AND t.archived_at IS NULL
         AND t.is_test_user IS NOT TRUE
         AND lower(COALESCE(t.role_category, '')) IN ('sales', 'retention')
    ) s
    LEFT JOIN public.team_on_time_annual_pay(p_agency_id) p
      ON p.team_member_id = s.id
    CROSS JOIN (SELECT public.raise_gap_scenario(p_agency_id) AS j) gp
   WHERE s.avg_sp IS NOT NULL;
$function$;
