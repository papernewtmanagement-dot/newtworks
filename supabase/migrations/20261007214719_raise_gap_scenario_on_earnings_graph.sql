-- Biggest gap to the next raise (Peter 2026-10-07). Sales seats for now; retention to follow.
-- For each line, swap last finished quarter's figure for the person's own best finished
-- quarter (since hire, last four), reprice through compute_sp_from_production, keep the
-- line that adds the most weekly sales points. Pace and next step come from
-- team_raise_progress, so the gap reads the same average the dot shows.
CREATE OR REPLACE FUNCTION public.raise_gap_scenario(p_agency_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb := '[]'::jsonb;
  r record;
  v_cs date;
  v_q record;
  v_qs jsonb;
  v_u jsonb;
  v_base jsonb;
  v_best jsonb;
  v_sp_base numeric;
  v_sp numeric;
  v_line text;
  v_pick text;
  v_lift numeric;
  v_pick_lift numeric;
  v_new_x numeric;
  v_tier integer;
  v_tier_rate numeric;
  v_hire date;
  v_n integer;
  v_weeks integer;
  i integer;
BEGIN
  PERFORM public.require_login('staff');
  SELECT c.cycle_start INTO v_cs FROM public.current_cycle_info(p_agency_id, p_as_of) c;

  FOR r IN SELECT * FROM public.team_raise_progress(p_agency_id, p_as_of, true) rp
            WHERE rp.role_category = 'Sales' AND NOT rp.at_top AND rp.avg_weekly_sp IS NOT NULL
              AND (public.is_agency_admin() OR rp.team_member_id = public.current_team_member_id())
  LOOP
    SELECT t.hire_date INTO v_hire FROM public.team t WHERE t.id = r.team_member_id;

    -- Finished quarters the person worked in full, newest first, up to four.
    v_qs := '[]'::jsonb;
    FOR i IN 1..4 LOOP
      SELECT * INTO v_q FROM public.current_cycle_info(p_agency_id, v_cs - 1 - 91 * (i - 1));
      EXIT WHEN v_hire IS NOT NULL AND v_q.cycle_start < v_hire;
      SELECT ps.sp->'units' INTO v_u
        FROM public.production_sales_points_for(p_agency_id, v_q.cycle_start, v_q.cycle_end) ps
       WHERE ps.team_member_id = r.team_member_id;
      v_qs := v_qs || jsonb_build_array(COALESCE(v_u, '{}'::jsonb) || jsonb_build_object('quarter', v_q.quarter_label));
    END LOOP;
    CONTINUE WHEN jsonb_array_length(v_qs) < 2;

    v_base := v_qs->0;
    v_sp_base := (public.compute_sp_from_production(
                   (v_base->>'auto_apps')::numeric, (v_base->>'fire_apps')::numeric,
                   (v_base->>'life_premium')::numeric, (v_base->>'health_premium')::numeric,
                   (v_base->>'auto_premium')::numeric, (v_base->>'fire_premium')::numeric)
                 ->'commission'->>'total_commission')::numeric;

    v_pick := NULL; v_pick_lift := 0; v_best := NULL;
    FOREACH v_line IN ARRAY ARRAY['auto', 'fire', 'life', 'health'] LOOP
      -- Own best finished quarter on this line.
      SELECT q INTO v_u FROM jsonb_array_elements(v_qs) q
       ORDER BY CASE WHEN v_line IN ('auto', 'fire') THEN (q->>(v_line || '_apps'))::numeric
                     ELSE (q->>(v_line || '_premium'))::numeric END DESC NULLS LAST
       LIMIT 1;
      v_sp := (public.compute_sp_from_production(
                 (CASE WHEN v_line = 'auto' THEN v_u ELSE v_base END->>'auto_apps')::numeric,
                 (CASE WHEN v_line = 'fire' THEN v_u ELSE v_base END->>'fire_apps')::numeric,
                 (CASE WHEN v_line = 'life' THEN v_u ELSE v_base END->>'life_premium')::numeric,
                 (CASE WHEN v_line = 'health' THEN v_u ELSE v_base END->>'health_premium')::numeric,
                 (CASE WHEN v_line = 'auto' THEN v_u ELSE v_base END->>'auto_premium')::numeric,
                 (CASE WHEN v_line = 'fire' THEN v_u ELSE v_base END->>'fire_premium')::numeric)
              ->'commission'->>'total_commission')::numeric;
      v_lift := (v_sp - v_sp_base) / 13.0;
      IF v_lift > v_pick_lift THEN
        v_pick := v_line; v_pick_lift := v_lift; v_best := v_u;
      END IF;
    END LOOP;
    CONTINUE WHEN v_pick IS NULL OR v_pick_lift < 1;

    v_new_x := ROUND(r.avg_weekly_sp + v_pick_lift, 1);
    SELECT p.raise_tier, p.base_hourly INTO v_tier, v_tier_rate
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
       AND p.sales_points <= v_new_x
     ORDER BY p.raise_tier DESC LIMIT 1;

    -- Weeks at the new pace until the next step's window average clears its bar,
    -- each new week replacing one at the current average.
    v_n := r.lookback_quarters * 13;
    v_weeks := CASE WHEN r.next_threshold IS NOT NULL AND v_new_x > r.next_threshold
                         AND r.avg_weekly_sp < r.next_threshold
                    THEN CEIL((r.next_threshold - r.avg_weekly_sp) * v_n / (v_new_x - r.avg_weekly_sp))::int END;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'team_member_id', r.team_member_id,
      'line',           v_pick,
      'line_label',     CASE v_pick WHEN 'auto' THEN 'Auto' WHEN 'fire' THEN 'Fire' WHEN 'life' THEN 'Life' ELSE 'Health' END,
      'measure',        CASE WHEN v_pick IN ('auto', 'fire') THEN 'apps' ELSE 'premium' END,
      'last_quarter',   v_base->>'quarter',
      'last_value',     CASE WHEN v_pick IN ('auto', 'fire') THEN (v_base->>(v_pick || '_apps'))::numeric ELSE (v_base->>(v_pick || '_premium'))::numeric END,
      'best_quarter',   v_best->>'quarter',
      'best_value',     CASE WHEN v_pick IN ('auto', 'fire') THEN (v_best->>(v_pick || '_apps'))::numeric ELSE (v_best->>(v_pick || '_premium'))::numeric END,
      'lift_weekly',    ROUND(v_pick_lift, 1),
      'x',              v_new_x,
      'reached_tier',   GREATEST(v_tier, COALESCE(r.current_tier, 0)),
      'reached_hourly', GREATEST(COALESCE(v_tier_rate, 0) + COALESCE(r.title_increment, 0), r.current_hourly),
      'current_hourly', r.current_hourly,
      'next_tier',      r.next_tier,
      'weeks_to_next',  v_weeks));
  END LOOP;
  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.raise_gap_scenario(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.raise_gap_scenario(uuid, date) TO authenticated, service_role;

-- Earnings graph: prorated dot plus each person's biggest-gap scenario.
CREATE OR REPLACE FUNCTION public.earnings_curve_positions(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
         AND (public.is_agency_admin()
              OR t.id = public.current_team_member_id())
    ) s
    LEFT JOIN public.team_on_time_annual_pay(p_agency_id) p
      ON p.team_member_id = s.id
    CROSS JOIN (SELECT public.raise_gap_scenario(p_agency_id) AS j) gp
   WHERE s.avg_sp IS NOT NULL;
$function$;

